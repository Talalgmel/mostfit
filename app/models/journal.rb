require 'builder'
class Journal
  include DataMapper::Resource
  include DateParser
  
  before :valid?, :parse_dates
 
  property :id,             Serial
  property :comment,        String
  property :transaction_id, String, :index => true  
  property :date,           Date,   :index => true, :default => Date.today
  property :created_at,     DateTime, :index => true  
  property :batch_id,       Integer, :nullable => true
  belongs_to :batch
  belongs_to :journal_type
  has n, :postings
  has n, :accounts, :through => :postings
  
  def validity_check
    return false if self.postings.length<2 #minimum one posting for credit n one for debit
    debit_account_postings, credit_account_postings = self.postings.group_by{|x| x.amount>0}.values

    #no debit account posting
    return [false, "no debit account posting"] if debit_account_postings.nil?  or debit_account_postings.length==0
    
    #no credit account posting
    return [false, "no credit account posting"] if credit_account_postings.nil? or credit_account_postings.length==0 
    
    #same debit and credit accounts
    return [false, "same debit and credit accounts"] if (credit_account_postings.map{|x| x.account_id} == debit_account_postings.map{|x| x.account_id})
    
    #cross branch posting
    return [false, "cross branch posting"] if self.postings.accounts.map{|x| x.branch_id}.uniq.length > 1
    
    #duplicate postings
    return [false, "duplicate accounts"] if self.postings.map{|x| x.account_id}.compact.length != self.postings.length
    
    #amount mismatch
    return [false, "debit and credit amount mismatch"] unless credit_account_postings.map{|x| x.amount * -1}.reduce(0){|s,x| s+=x}  ==  debit_account_postings.map{|x| x.amount}.reduce(0){|s,x| s+=x}
    
    return [true, ""]
  end


  def self.create_transaction(journal_params, debit_accounts, credit_accounts)
    # debit and credit accounts can be either hashes or objects
    # In case of hashes, this is the structure
    # debit_accounts =>  {Account.get(1) => 100, Account.get(2) => 30}
    # credit_accounts => {Account.get(3) => 200}
    # Otherwise we have account object as credit_account & debit_account 
    # and we have a amount key in journal_params which has the amount
    
    status = false
    journal = nil

    transaction do |t|
     
      journal = Journal.create(:comment => journal_params[:comment], :date => journal_params[:date]||Date.today,
                               :transaction_id => journal_params[:transaction_id],
                               :journal_type_id => journal_params[:journal_type_id])
      
      amount = journal_params.key?(:amount) ? journal_params[:amount].to_i : nil

      #debit entries
      # when a voucher is created manually, debit_accounts and credit_accounts are not hasahes.
      # TODO: fix this
      if debit_accounts.is_a?(Hash)
        debit_accounts.each{|debit_account, debit_amount|
          Posting.create(:amount => (debit_amount||amount) * -1, :journal_id => journal.id, :account => debit_account, :currency => journal_params[:currency])
        }
      else
        Posting.create(:amount => amount * -1, :journal_id => journal.id, :account => debit_accounts, :currency => journal_params[:currency])
      end
      
      #credit entries
      if credit_accounts.is_a?(Hash)
        credit_accounts.each{|credit_account, credit_amount|
          Posting.create(:amount => (credit_amount||amount), :journal_id => journal.id, :account => credit_account, :currency => journal_params[:currency])
        }
      else
        Posting.create(:amount => amount, :journal_id => journal.id, :account => credit_accounts, :currency => journal_params[:currency])
      end
      
      # Rollback in case of both accounts being the same      
      status, reason = journal.validity_check
      unless status
        t.rollback
        status = false
        journal.errors.add(:postings, reason)
      end
    end

    return [status, journal]
  end
  
  def self.for_branch(branch, offset=0, limit=25)
    sql  = %Q{
              SELECT j.id, j.comment comment, j.date date, SUM(if(p.amount>0, p.amount, 0)) amount, 
              group_concat(ca.name) credit_accounts, group_concat(da.name) debit_accounts
              FROM journals j, accounts a, postings p
              LEFT OUTER JOIN accounts da ON p.account_id=da.id AND p.amount<0
              LEFT OUTER JOIN accounts ca ON p.account_id=ca.id AND p.amount>0
              WHERE a.branch_id=#{branch.id} AND a.id=p.account_id and p.journal_id=j.id
              GROUP BY j.id
              ORDER BY j.created_at DESC
              OFFSET #{offset}
              LIMIT #{limit}
              }
    repository.adapter.query(sql)
  end
  

  def self.xml_tally(hash={}, xml_file = nil)
    xml_file ||= '/tmp/voucher.xml'
    f = File.open(xml_file,'w')
    x = Builder::XmlMarkup.new(:indent => 1)
    x.ENVELOPE{
      x.HEADER {    
        x.VERSION "1"
        x.TALLYREQUEST "Import"
        x.TYPE "Data"
        x.ID "Vouchers"  
      }
      
      x.BODY { 
        x.DESC{
        }
        x.DATA{
          x.TALLYMESSAGE{
            Journal.all(hash).each do |j|
              debit_posting, credit_posting = j.postings
              x.VOUCHER{
                x.DATE j.date.strftime("%Y%m%d")
                x.NARRATION j.comment
                x.VOUCHERTYPENAME j.journal_type.name
                x.VOUCHERNUMBER j.id
                x.tag! 'ALLLEDGERENTRIES.LIST' do
                  x.LEDGERNAME(credit_posting.account.name)
                  x.ISDEEMEDPOSITIVE("No")
                  x.AMOUNT(credit_posting.amount)
                end
                x.tag! 'ALLLEDGERENTRIES.LIST' do
                  x.LEDGERNAME(debit_posting.account.name)
                  x.ISDEEMEDPOSITIVE("Yes")
                  x.AMOUNT(debit_posting.amount)
                end
              }
            end
          }
        }
      }
    } 
    f.write(x)
    f.close
  end 
end
