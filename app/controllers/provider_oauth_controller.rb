class ProviderOauthController < ApplicationController
  skip_before_action :verify_authenticity_token

  layout "bootstrap"

  def self.controller_path
    "oauth"
  end

  # OAuth2 assertion flow: http://tools.ietf.org/html/draft-ietf-oauth-assertions-01#section-6.3
  # Accepts Facebook and Google access tokens and returns an iNat access token
  def assertion
    assertion_type = params[:assertion_type] || params[:grant_type]
    client = Doorkeeper::Application.find_by_uid(params[:client_id])
    if assertion_type.blank? || client.blank?
      render :status => :unauthorized, :json => { :error => t( "doorkeeper.errors.messages.access_denied" ) }
      return
    end
    access_token = begin
      Timeout::timeout( 10 ) do
        case assertion_type
        when /facebook/
          oauth_access_token_from_facebook_token( params[:client_id], params[:assertion] )
        when /google/
          oauth_access_token_from_google_token( params[:client_id], params[:assertion] )
        when /apple/
          oauth_access_token_from_apple_assertion( params[:client_id], params[:assertion] )
        end
      end
    rescue Timeout::Error
      render status: :gateway_timeout, json: { error: t( "doorkeeper.errors.messages.temporarily_unavailable" ) }
      return
    end

    if access_token
      auth = Doorkeeper::OAuth::TokenResponse.new( access_token )
      # The following frmat stuff is a hack around a bug in the Android app;
      # remove when possible
      if request&.format&.json? || ( params[:frmat] && params[:frmat] == "json" )
        render json: auth.body, status: auth.status
      else
        uri = URI.parse( access_token.application.redirect_uri )
        uri.query = Rack::Utils.build_query(
          :access_token => auth.token.token,
          :token_type   => auth.token.token_type,
          :expires_in   => auth.token.expires_in
        )
        redirect_to uri.to_s
      end
    else
      render :status => :unauthorized, :json => { :error => t( "doorkeeper.errors.messages.access_denied" ) }
    end
  end

  private
  def oauth_access_token_from_facebook_token(client_id, provider_token)
    client = Doorkeeper::Application.find_by_uid(client_id)
    return nil unless client
    user = if (pa = ProviderAuthorization.where(:provider_name => "facebook", :token => provider_token).first)
      pa.user
    end
    user ||= begin
      fb = Koala::Facebook::API.new(provider_token)
      r = fb.get_object( "me", fields: "id,email,name,first_name,last_name,about,link,website,location,verified" )
      user = User.joins(:provider_authorizations).
        where("provider_authorizations.provider_uid = ?", r['id']).
        where("provider_authorizations.provider_name = 'facebook'").
        first
      user ||= User.where("email = ?", r['email']).first
      if user.blank?
        uid = r['id']
        auth_info = {
          'provider' => 'facebook',
          'uid' => uid,
          'info' => {
            'email' => r['email'],
            'name' => r['name'],
            'first_name' => r['first_name'],
            'last_name' => r['last_name'],
            'image' => "http://graph.facebook.com/#{uid}/picture?type=square",
            'description' => r['about'],
            'urls' => {
              'Facebook' => r['link'],
              'Website' => r['website']
            },
            'location' => (r['location'] || {})['name'],
            'verified' => r['verified']
          },
          'credentials' => {
            'token' => provider_token
          }
        }
        user = User.create_from_omniauth(auth_info)
      end
      user
    rescue Koala::Facebook::AuthenticationError => e
      Rails.logger.debug "[DEBUG] Failed to get fb user info from token: #{e}"
      nil
    end
    return nil unless user
    assertion_access_token_for_client_and_user( client, user )
  end

  def oauth_access_token_from_google_token(client_id, provider_token)
    client = Doorkeeper::Application.find_by_uid(client_id)
    user = if (pa = ProviderAuthorization.where(:provider_name => "google_oauth2", :token => provider_token).first)
      pa.user
    end
    user ||= begin
      r = RestClient.get( "https://www.googleapis.com/userinfo/v2/me", {
        Authorization: "Bearer #{provider_token}",
        "User-Agent" => "iNaturalist/Google"
      } )
      json = JSON.parse(r.body)
      unless uid = json['id']
        Rails.logger.debug "[DEBUG] Google auth failed: #{json.inspect}"
        return nil
      end
      user = User.joins(:provider_authorizations).
        where("provider_authorizations.provider_uid = ?", uid).
        where("provider_authorizations.provider_name = 'google_oauth2'").
        first
      if user.blank?
        auth_info = {
          'provider' => 'google_oauth2',
          'uid' => uid,
          'info' => {
            'email' => json['email'],
            'name' => json['name'],
            'first_name' => json['given_name'],
            'last_name' => json['family_name'],
            'image' => json['picture'],
            'urls' => {
              'Google Plus' => json['link']
            },
            'verified' => json['verified_email']
          },
          'credentials' => {
            'token' => provider_token
          }
        }
        user = User.create_from_omniauth( auth_info )
      end
      user
    rescue RestClient::Unauthorized => e
      Rails.logger.debug "[DEBUG] Failed to make a Google API call: #{e}"
      nil
    end

    return nil unless user && user.persisted?
    assertion_access_token_for_client_and_user( client, user )
  end

  def oauth_access_token_from_apple_assertion( client_id, assertion )
    client = Doorkeeper::Application.find_by_uid( client_id )
    if client.blank?
      error_message = "Client does not exist for Apple assertion: #{client_id}"
      Rails.logger.error = error_message
      LogStasher.write_hash(
        error_message: error_message,
        request: request,
        session: session,
        user: current_user
      )
      return
    end
    # Note that the assertion we are expecting from our own iPhone app is a JSON
    # string that contains the identity token as well as name details that are
    # (apprently) only available to the app
    assertion_json = begin
      JSON.parse( assertion )
    rescue JSON::ParserError, TypeError => e
      Rails.logger.error "Failed to parse Apple assertion: #{e}"
      Logstasher.write_exception( e, request: request, session: session, user: current_user )
      return
    end
    id_token = assertion_json["id_token"]
    if id_token.blank?
      error_message = "Failed to parse id_token out of Apple assertion"
      Rails.logger.error = error_message
      LogStasher.write_hash(
        error_message: error_message,
        request: request,
        session: session,
        user: current_user
      )
      return
    end
    jwks = JSON.parse(
      RestClient.get( "https://appleid.apple.com/auth/keys" ).body,
      symbolize_names: true
    )
    # CONFIG.apple.client_id is the client ID for the *web*. Assertions from the
    # app will use the package ID... which should probably be specified
    # separately in the config, but this works for now
    iphone_app_id = CONFIG.apple.app_id
    # JWT is handling the JWS signature verification using the JWKs. That's a
    # lot of JW
    id_token_conents, _header = ::JWT.decode( id_token, nil, true, {
      verify_iss: true,
      iss: "https://appleid.apple.com",
      verify_iat: true,
      verify_aud: true,
      aud: [iphone_app_id], #.concat(options.authorized_client_ids),
      algorithms: ["RS256"],
      jwks: jwks
    } )
    # Verify the contents of the token
    issuer_is_apple = id_token_conents["iss"] == "https://appleid.apple.com"
    audience_is_inat = id_token_conents["aud"] == iphone_app_id
    token_is_current = Time.now < Time.at( id_token_conents["exp"] )
    if !( issuer_is_apple && audience_is_inat && token_is_current )
      error_message = "Invalid identity token. iss: #{id_token_conents["iss"]}, aud: #{id_token_conents["aud"]}, exp: #{id_token_conents["exp"]} "
      Rails.logger.error = error_message
      LogStasher.write_hash(
        error_message: error_message,
        request: request,
        session: session,
        user: current_user
      )
      return
    end
    # Get the Apple unique user identifier (the "sub"ject)
    provider_uid = id_token_conents["sub"]
    if provider_uid.blank?
      error_message = "No user identifier in the Apple identity token"
      Rails.logger.error = error_message
      LogStasher.write_hash(
        error_message: error_message,
        request: request,
        session: session,
        user: current_user
      )
      return
    end
    existing_pa = ProviderAuthorization.where( provider_name: "apple", provider_uid: provider_uid ).first
    user = existing_pa&.user
    user ||= User.find_by_email( id_token_conents["email"] ) unless id_token_conents["email"].blank?
    unless user
      auth_info = {
        "provider" => "apple",
        "uid" => provider_uid,
        "info" => {
          "email" => id_token_conents["email"],
          "name" => assertion_json["name"],
          "verified" => id_token_conents["email_verified"] == "true"
        }
      }
      user = User.create_from_omniauth( auth_info )
    end
    return nil unless user && user.persisted?
    if access_token = assertion_access_token_for_client_and_user( client, user )
      # We could get into a situation where the token was created but no
      # ProviderAuthorization records was created if an existing user was found
      # via email and User.create_from_omniauth wasn't called, so we make
      # absolutely sure it exists here
      existing_pa = ProviderAuthorization.where(
        provider_name: "apple",
        provider_uid: provider_uid
      ).first
      if !existing_pa
        ProviderAuthorization.create!(
          provider_name: "apple",
          provider_uid: provider_uid,
          user: user
        )
      end
    end
    access_token
  end

  def assertion_access_token_for_client_and_user( client, user )
    access_token = Doorkeeper::AccessToken.
      where( application_id: client.id, resource_owner_id: user.id, revoked_at: nil ).
      order( "created_at desc" ).
      limit( 1 ).
      first
    if client.trusted?
      if access_token
        # If the user already has a token for this client, ensure that the
        # scopes match what they're requesting
        access_token.update( scopes: scopes_from_params( params, client ) )
      else
        access_token = Doorkeeper::AccessToken.create!(
          application_id: client.id,
          resource_owner_id: user.id,
          scopes: scopes_from_params( params, client )
        )
      end
    end
    access_token
  end

  def scopes_from_params( params, client )
    allowed_scopes = client.scopes.try(:to_a) || []
    requested_scopes = params[:scope].to_s.split( /\s/ ).compact.uniq
    scopes = allowed_scopes & requested_scopes
    scopes = Doorkeeper.configuration.default_scopes.to_a if scopes.blank?
    scopes.join( " " )
  end
end
