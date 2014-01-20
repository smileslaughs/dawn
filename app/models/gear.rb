class Gear

  include Mongoid::Document
  include Mongoid::Timestamps

  field :type,         type: Symbol  # worker type: web/...
  field :number,       type: Integer # 1,2,3
  field :port,         type: Integer # outbound port of the container
  field :ip,           type: String  # network IP of the container
  field :container_id, type: String  # pid/identifier of the Docker container
  field :started_at,   type: Time,   default: ->{ Time.now }

  validates_uniqueness_of :container_id, :ip # :name

  # before_create create a docker container and run the worker, set port/ip/container_id
  before_create do |gear|
    # TEMP? might not be cross process safe, need to make it Atomic
    gear.number = app.gears.where(type: type).count + 1
    gear.port = 5000 # temp?

    logshuttle = {
      procid: name,
      :'logplex-token' => app.logplex_tokens['app'],
      :'logs-url' => "http://#{ENV['DAWN_HOST']}:8601/logs"
    }

    opts = logshuttle.map {|key, val| "-#{key}=#{val.inspect}" }.join(" ")
    command = %{/bin/bash -c '/start #{type} 2>&1 | /opt/log-shuttle/log-shuttle #{opts}'}
                                                           # FUGLY, FIX!
    gear.container_id = `docker run -d -e PORT=#{port} #{app.releases.last.image} #{command}`.chomp

    info = gear.send(:docker_container).json
    gear.ip = info["NetworkSettings"]["IPAddress"]

    # update Hipache with the new gear IP/ports (only add web gears)
    redis_key = "frontend:#{app.url}"
    $redis.rpush(redis_key, "http://#{gear.ip}:#{gear.port}") if gear.type == :web
  end

  before_destroy do |gear|
    # remove gear from Hipache
    redis_key = "frontend:#{app.url}"
    $redis.lrem(redis_key, 1, "http://#{gear.ip}:#{gear.port}") if gear.type == :web
  end

  after_destroy do # destroy the accompanying docker container
    stop && remove
  end

  def name # full name: web.1, mailer.3 (type.number)
    "#{type}.#{number}"
  end

  def uptime
    started_at ? Time.now - started_at : 0
  end

  def reset_started_at
    update(started_at: Time.now)
  end
  private :reset_started_at

  def docker_container
    Docker::Container.get(container_id)
  end
  private :docker_container

  def kill
    docker_container.kill
  end

  def start
    docker_container.start
    reset_started_at
  end

  def stop
    docker_container.stop
  end

  def restart # use docker restart
    docker_container.restart
    reset_started_at
  end

  def remove
    docker_container.delete
  end

  belongs_to :app

end