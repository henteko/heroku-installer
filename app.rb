Bundler.require
require "tmpdir"
require "shellwords"
require "json"
require "pty"
require "heroku/client/rendezvous"

class Throttle
  def initialize(threshold)
    @threshold = threshold
    @lock = false
  end

  def emit
    unless @lock
      @lock = true
      yield

      Thread.new do
        sleep @threshold
        @lock = false
      end
    end
  end
end

def git(*args)
  args.unshift "git"

  PTY.getpty(args.map(&:to_s).map(&:shellescape).join(" ")) do |o, i|
    IO.copy_stream(o, STDOUT) rescue nil
  end
end

def install_app(repo, params)
  app_name, api_key = params.values_at(:app_name, :api_key)
  puts "Initializing heroku application ..."

  begin
    heroku = Heroku::API.new(api_key: api_key)
    heroku.post_app(name: app_name, stack: "cedar")
    heroku.post_collaborator(app_name, ENV["HEROKU_ACCOUNT"])
  rescue Heroku::API::Errors::RequestFailed
    raise "Heroku error: " + JSON.parse($!.response.body)["error"]
  rescue Heroku::API::Errors::Unauthorized
    raise "API key maybe invalid."
  rescue
    raise "Heroku is dead."
  end

  begin
    Dir.mktmpdir do |repo_path|
      git :clone, repo, repo_path

      Dir.chdir(repo_path) do
        conf = {}

        if File.exist?(".heroku-installer")
          conf = YAML.load(open(".heroku-installer"))
        end

        conf["addons"].to_a.each do |addon|
          heroku.post_addon(app_name, addon)
        end

        heroku.put_config_vars(app_name, conf["config"] || {})
        git :remote, :add, :heroku, "git@heroku.com:%s.git" % app_name
        git :push, :heroku, :master

        conf["script"].to_a.each do |command|
          process = heroku.post_ps(app_name, command, attach: true).body
          Heroku::Client::Rendezvous.new(
            rendezvous_url: process["rendezvous_url"],
                    output: STDOUT
          ).start
        end
      end
    end

    heroku.delete_collaborator(app_name, ENV["HEROKU_ACCOUNT"])
  rescue
    heroku.delete_app(app_name)
    raise $!
  end
end

helpers do
  def h(s)
    Rack::Utils.escape_html(s.to_s)
  end
end

configure do
  Pusher.app_id = ENV["PUSHER_APPID"]
  Pusher.key    = ENV["PUSHER_KEY"]
  Pusher.secret = ENV["PUSHER_SECRET"]

  netrc = Netrc.read(".netrc")
  netrc["api.heroku.com"] =
  netrc["code.heroku.com"] =
    ENV.values_at("HEROKU_ACCOUNT", "HEROKU_APIKEY")
  netrc.save
end

get "/" do
  Kramdown::Document.new(File.read("README.md")).to_html
end

"/install/git:/*".tap do |it|
  before it do |repo|
    @repo = "git://" + repo
  end

  get it do
    @repo_name = @repo[%r"[^/]+$"].chomp(".git")
    erb :install
  end

  post it do
    fork do
      channel = Pusher[params[:app_name]]
      buffer = IO.pipe

      Thread.new do
        throttle = Throttle.new(0.2)
        line = ""
        buffer.first.each(1) do |c|
          if c == "\r" || c == "\n"
            throttle.emit { channel.trigger("log", line) } unless line.empty?
            line.clear
            next
          end

          line << c
        end
      end

      STDOUT.reopen(buffer.last)

      begin
        install_app @repo, params
      rescue
        channel.trigger("error", $!.message)
        break
      end

      channel.trigger("complete", "Deployed application at http://%s.herokuapp.com/" % params[:app_name])
    end

    204
  end
end
