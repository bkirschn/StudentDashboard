# Utility class to run requests against a WSO2 API.
# This has two entry points of interest:

# Constructor: new(hash)
# The hash should contain the following values:
# 'token_server','api_prefix','key','secret'
# It may contain the current token value but does not need to
# since WAPI will renew tokens as necessary.

# get_request(string): This string will be appended to the api_prefix and
# executed as a GET

# Only GET is explicitly supported at the moment.

require 'base64'
require 'rest-client'
require_relative './Logging'

include Logging

class WAPI

  # key and secret are oauth key and secret for generating tokens.
  # token_server is full url for request to generate / renew tokens.
  #
  # api_prefix is string that will be prefixed to every request made
  # through this instance.  It will contain host and may anything else
  # that will appear in front of every request.  E.g. It might contain
  # https://woodpigeon.dsc.umich.edu:8243/StudentDashboard/v1 or just
  # https://woodpigeon.dsc.umich.edu:8243 depending on how you choose
  # to use it.

  def initialize(application)
    #puts "in WAPI initialize"
    if application.nil?
      msg = "No ESB Application values provided to WAPI initialize"
      logger.warn msg
      raise StandardError, msg
    end

    @token_server = application['token_server']
    @api_prefix = application['api_prefix']
    @key = application['key']
    @secret = application['secret']
    @token = application['token']

    # ## special uniqname may be supplied for testing
    @uniqname = application['uniqname']

    @renewal = WAPI.build_renewal(@key, @secret)
    logger.debug("WAPI: #{__LINE__}: initialize WAPI with #{@api_prefix}")
  end


  ### Consider making this a separate class with helpful methods
  ### to access portions of the result and to convert types.
  def self.wrap_result(status, msg, result)
    Hash["Meta" => Hash["httpStatus" => status,
                        "Message" => msg],
         "Result" => result]
  end


  def self.build_renewal(key, secret)
    b64 = base64_key_secret(key, secret)
    "Basic #{b64}"
  end

  def self.base64_key_secret(key, secret)
    ks = "#{key}:#{secret}"
    Base64.strict_encode64(ks)
  end

# use instance information to generate the proper url
  def format_url(request)
    "#{@api_prefix}#{request}"
  end

## Internal method to actually make the request
## Whatever happens it will be wrapped into a standard object.
  def do_request(request)
    url=format_url(request)
    logger.debug "WAPI: do_request: url: #{url}"
    begin
      response = RestClient.get url, {:Authorization => "Bearer #{@token}",
                                      :accept => :json,
                                      :verify_ssl => true}

      logger.debug "WAPI: #{__LINE__}: do_request: successful response: "
      wrapped_response = WAPI.wrap_result(response.code, "COMPLETED", response)
    rescue Exception => exp
#      logger.debug "WAPI: #{__LINE__}: do_request: http_code: "+exp.http_code.to_s
      wrapped_response = WAPI.wrap_result(666, "EXCEPTION", exp)
    end
    wrapped_response
  end

## Run the request.  If the result is unauthorized then renew the token and try again.
## In any case will return a wrapped result.

  def get_request(request)
    wrapped_response = do_request(request)
    logger.debug("WAPI: #{__LINE__}: response: A "+wrapped_response.inspect)

    logger.debug "WAPI: #{__LINE__}: wrapped_response result: "+wrapped_response['Result'].inspect

    ## If appropriate try to renew the token.
    ###### Note that need end multi-line conditional tests with operator to let it know
    ###### there is more to come.
    if wrapped_response['Meta']['httpStatus'] == 666 &&
        wrapped_response['Result'].respond_to?('http_code') &&
        wrapped_response['Result'].http_code == 401
      logger.debug("WAPI: #{__LINE__}: unauthorized on initial request: "+wrapped_response.inspect)
      wrapped_response = renew_token()
      ## if the token renewed ok then try the request again.
      if wrapped_response['Meta']['httpStatus'] == 200
        logger.debug("WAPI: #{__LINE__}: retrying request after token renewal")
        wrapped_response = do_request(request)
      end
    end
    #logger.debug "WAPI: #{__LINE__}: wrapped_response: "+wrapped_response.inspect
    wrapped_response
  end

# Renew the current token.  Will set the current @token value in the object
  def renew_token

    #puts "WAPI: renewing token: #{@token}"
    logger.debug "WAPI: renew_token"
    begin
      response = RestClient.post @token_server,
                                 "grant_type=client_credentials&scope=PRODUCTION",
                                 {
                                     :Authorization => @renewal,
                                     :content_type => "application/x-www-form-urlencoded"
                                 }
      ## If it worked then parse the result.  This is here to capture any JSON parsing exceptions.
      if response.code == 200
        ## will need to get the access_token below.  If it is not JSON that is an error.
        s = JSON.parse(response)
        @token = s['access_token']
      end
    rescue Exception => exp
      # If got an exception for the renewal wrap that up to be returned.
      logger.debug("WAPI: #{__LINE__}: renewal post exception: "+exp.to_json+":"+exp.http_code.to_s)
      wr = WAPI.wrap_result(exp.http_code, "EXCEPTION DURING TOKEN RENEWAL", exp)
      return wr
    end

    logger.warn("WAPI: #{__LINE__}: got response: "+response.inspect)

    ## got no response or an error, wrap that up.
    if response.nil?
      logger.warn("WAPI: #{__LINE__}: error renewing token: nil response ")
      wr = WAPI.wrap_result(666, "error renewing token: nil response", response)
    elsif response.code != 200
      logger.warn("WAPI: #{__LINE__}: error renewing token: response code: "+response.code)
      wr = WAPI.wrap_result(666, "error renewing token: response code", response)
    else
      print_token = sprintf "%5s", @token
      logger.debug("WAPI: #{__LINE__}: renewed token: #{print_token}")
      wr = WAPI.wrap_result(200, "token renewed", response)
    end
    wr
  end

  # Make the result be wrapped in valid json object
  #  {
  #      Meta: { httpStatus: 200, Message: "everything was cool"},
  #      Result: ["Feeling", "Groovy"]
  #  }

  #  def self.wrap_result(status,msg,result)
  #    Hash["Meta" => Hash["httpStatus" => status,
  #                        "Message" => msg],
  #         "Result" => result]
  #  end

end
