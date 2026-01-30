require 'tmpdir'
require 'webrick'
require 'net/http'
require 'base64'
require 'json'

$entrypoint = '__VC_HANDLER_FILENAME'

ENV['RAILS_ENV'] ||= 'production'
ENV['RACK_ENV'] ||= 'production'
ENV['RAILS_LOG_TO_STDOUT'] ||= '1'

def rack_handler(httpMethod, path, body, headers)
  require 'rack'

  app, _ = Rack::Builder.parse_file($entrypoint)
  server = Rack::MockRequest.new app

  env = headers.transform_keys { |k| k.split('-').join('_').prepend('HTTP_').upcase }
  res = server.request(httpMethod, path, env.merge({ :input => body }))

  {
    :statusCode => res.status,
    :headers => res.original_headers,
    :body => res.body,
  }
end

def webrick_handler(httpMethod, path, body, headers)
  require_relative $entrypoint

  if not Object.const_defined?('Handler')
    return { :statusCode => 500, :body => 'Handler not defined in lambda' }
  end

  host = '0.0.0.0'
  port = 3000

  server = WEBrick::HTTPServer.new :BindAddress => host, :Port => port

  if Handler.is_a?(Proc)
    server.mount_proc '/', Handler
  else
    server.mount '/', Handler
  end

  th = Thread.new(server) do |server|
    server.start
  end

  http = Net::HTTP.new(host, port)
  res = http.send_request(httpMethod, path, body, headers)

  Signal.list.keys.each do |sig|
    begin
      Signal.trap(sig, cleanup)
    rescue
    end
  end

  server.shutdown
  Thread.kill(th)

  # Net::HTTP doesn't read the set the encoding so we must set manually.
  # Bug: https://bugs.ruby-lang.org/issues/15517
  # More: https://yehudakatz.com/2010/05/17/encodings-unabridged/
  res_headers = res.each_capitalized.to_h
  if res_headers["Content-Type"] && res_headers["Content-Type"].include?("charset=")
    res_encoding = res_headers["Content-Type"].match(/charset=([^;]*)/)[1]
    res.body.force_encoding(res_encoding)
    res.body = res.body.encode(res_encoding)
  end

  {
    :statusCode => res.code.to_i,
    :headers => res_headers,
    :body => res.body.nil? ? "" : res.body,
  }
end

def vc__handler(event:, context:)
  payload = JSON.parse(event['body'])
  path = payload['path']
  headers = payload['headers']

  if ENV['VERCEL_DEBUG']
    puts 'Request Headers: '
    puts headers
  end

  httpMethod = payload['method']
  encoding = payload['encoding']
  body = payload['body']

  if (not body.nil? and not body.empty?) and (not encoding.nil? and encoding == 'base64')
    body = Base64.decode64(body)
  end

  if $entrypoint.end_with? '.ru'
    return rack_handler(httpMethod, path, body, headers)
  end

  return webrick_handler(httpMethod, path, body, headers)
end
