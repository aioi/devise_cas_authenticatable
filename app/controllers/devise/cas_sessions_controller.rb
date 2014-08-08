class Devise::CasSessionsController < Devise::SessionsController
  include DeviseCasAuthenticatable::SingleSignOut::DestroySession
  include Devise::Controllers::InternalHelpers
  unloadable

  skip_before_filter :verify_authenticity_token, :only => [:single_sign_out]

  def new
    unless returning_from_cas?
      redirect_to(cas_login_url)
    end
  end

  def service
    # store service ticket for later to be used by Application clients as an API access key
    # use Thread.current in stead of session because this action 'service' was being redirected from CAS
    # server multiple times during sign up, params[:ticket] filled with proxy service ticket and service ticket
    # respectively depending on sessions, sometimes, it was found, during the test, that app client ends up with
    # proxy service ticket session. The proxy service ticket can not be used as a key because it only exists on
    # CAS server temporarily.
    # The service ticket is what the client apps need and is the last one to arrive,
    # which will be stored in Thread.current[:ticket]
    Thread.current[:ticket] = params[:ticket]
    redirect_to after_sign_in_path_for(warden.authenticate!(:scope => resource_name))
  end

  def unregistered
  end

  def destroy
    # if :cas_create_user is false a CAS session might be open but not signed_in
    # in such case we destroy the session here
    if signed_in?(resource_name)
      sign_out(resource_name)
    else
      reset_session
    end

    redirect_to(logout_url)
  end

  def single_sign_out
    if ::Devise.cas_enable_single_sign_out
      session_index = read_session_index
      if session_index
        logger.debug "Intercepted single-sign-out request for CAS session #{session_index}."
        session_id = ::DeviseCasAuthenticatable::SingleSignOut::Strategies.current_strategy.find_session_id_by_index(session_index)
        if session_id
          destroy_cas_session(session_id, session_index)
        end
      else
        logger.warn "Ignoring CAS single-sign-out request as no session index could be parsed from the parameters."
      end
    else
      logger.warn "Ignoring CAS single-sign-out request as feature is not currently enabled."
    end

    render :nothing => true
  end

  private

  def read_session_index
    if request.headers['CONTENT_TYPE'] =~ %r{^multipart/}
      false
    elsif request.post? && params['logoutRequest'] =~
        %r{^<samlp:LogoutRequest.*?<samlp:SessionIndex>(.*)</samlp:SessionIndex>}m
      $~[1]
    else
      false
    end
  end

  def destroy_cas_session(session_id, session_index)
    logger.debug "Destroying cas session #{session_id} for ticket #{session_index}"
    if destroy_session_by_id(session_id)
      logger.debug "Destroyed session #{session_id} corresponding to service ticket #{session_index}."
    end

    ::DeviseCasAuthenticatable::SingleSignOut::Strategies.current_strategy.delete_session_index(session_index)
  end

  def returning_from_cas?
    params[:ticket] || request.referer =~ /^#{::Devise.cas_client.cas_base_url}/ || request.referer =~ /^#{url_for :action => "service"}/
  end

  def cas_login_url
    ::Devise.cas_client.add_service_to_login_url(::Devise.cas_service_url(request.url, devise_mapping))
  end
  helper_method :cas_login_url

  def request_url
    return @request_url if @request_url
    @request_url = request.protocol.dup
    @request_url << request.host
    @request_url << ":#{request.port.to_s}" unless request.port == 80
    @request_url
  end

  def destination_url
    return unless ::Devise.cas_logout_url_param == 'destination'
    if !::Devise.cas_destination_url.blank?
      url = Devise.cas_destination_url
    else
      url = request_url.dup
      url << after_sign_out_path_for(resource_name)
    end
  end

  def follow_url
    return unless ::Devise.cas_logout_url_param == 'follow'
    if !::Devise.cas_follow_url.blank?
      url = Devise.cas_follow_url
    else
      url = request_url.dup
      url << after_sign_out_path_for(resource_name)
    end
  end

  def service_url
    ::Devise.cas_service_url(request_url.dup, devise_mapping)
  end

  def logout_url
    begin
      ::Devise.cas_client.logout_url(destination_url, follow_url, service_url)
    rescue ArgumentError
      # Older rubycas-clients don't accept a service_url
      ::Devise.cas_client.logout_url(destination_url, follow_url)
    end
  end
end
