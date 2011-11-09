class Uploads < Application

  before do
    raise NotAcceptable unless Mfi.first.system_state == :migration
  end

  def upload_status        
    render
  end

  def index
    hash = session.user.admin? ? {} : {:user => session.user}
    @uploads = Upload.all(hash.merge(:order => [:updated_at]))
    display @uploads
  end

  def new
    @upload = Upload.new
    display @upload
  end
  
  def create
    debugger
    erase = params.has_key?(:erase)
    if params[:file] and params[:file][:filename] and params[:file][:tempfile]
      file      = Upload.make(params.merge(:user => session.user))
    else
      render
    end
  end

  def show(id)
    @upload = Upload.get(id)
    raise NotFound unless @upload
    display @upload
  end

  def continue(id)
    if request.xhr?
      @upload = Upload.get(id)
      raise NotFound unless @upload
      Merb.run_later do
        @upload.cont
      end
    else
      @upload = Upload.get(id)
      raise NotFound unless @upload
      display @upload
    end
  end
  
  def reset(id)
    @upload = Upload.get(id)
    raise NotFound unless @upload
    @upload.reset(params[:restart])
    redirect resource(@upload), :message => {:notice => "This upload was succesfully reset"}

  end

  def edit(id)
    @upload = Upload.get(id)
    raise NotFound unless @upload
    display @upload
  end

  def update(id, upload)
    @upload = Upload.get(id)
    raise NotFound unless @upload
    if params[:file] and params[:file][:filename] and params[:file][:tempfile]
      @upload.move(params[:file][:tempfile].path)
      redirect resource(@upload), :message => {:notice => "File has been replaced. Click continue to extract"}
    else
      render
    end
  end



    

  
end
