"""
Auto-generated template used by vercel dev (Ruby, Rack)
Serves static files from PUBLIC_DIR before delegating to the user Rack app.

This file is written to the project at .vercel/ruby/vc_init_dev.rb
and executed by the dev server launcher.
"""

require 'rack'
require 'rack/handler/webrick'
require 'webrick'
require 'socket'

$stdout.sync = true
$stderr.sync = true

USER_ENTRYPOINT = "__VC_DEV_ENTRYPOINT__"
PUBLIC_DIR = 'public'

def build_user_app
  if USER_ENTRYPOINT.end_with?('.ru')
    app, _ = Rack::Builder.parse_file(USER_ENTRYPOINT)
    app
  else
    # For dev we only support Rack entrypoints (.ru) to ensure consistent behavior
    abort("Unsupported entrypoint: #{USER_ENTRYPOINT}. Please use a Rack config (.ru) file for vercel dev.")
  end
end

class StaticThenApp
  def initialize(app, public_dir)
    @app = app
    @public_dir = public_dir
    @file_server = Rack::File.new(public_dir)
    @base = File.expand_path(public_dir)
  end

  def call(env)
    req_path = env['PATH_INFO'] || '/'
    # Normalize path and guard against traversal
    safe = req_path.sub(/^\//, '')
    full = File.expand_path(safe, @base)

    if full.start_with?(@base + File::SEPARATOR) && File.file?(full)
      # Delegate to Rack::File which handles HEAD/GET correctly
      return @file_server.call(env)
    end

    @app.call(env)
  end
end

def static_then_app(user_app)
  StaticThenApp.new(user_app, PUBLIC_DIR)
end

host = '127.0.0.1'
begin
  sock = TCPServer.new(host, 0)
  port = sock.addr[1]
ensure
  sock&.close
end

app = static_then_app(build_user_app)

logger = WEBrick::Log.new($stderr)
logger.level = WEBrick::Log::WARN
server = WEBrick::HTTPServer.new(
  BindAddress: host,
  Port: port,
  AccessLog: [],
  Logger: logger
)

# Mount the Rack app at root
server.mount '/', Rack::Handler::WEBrick, app

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

puts "Serving on http://#{host}:#{server.config[:Port]}"
server.start
