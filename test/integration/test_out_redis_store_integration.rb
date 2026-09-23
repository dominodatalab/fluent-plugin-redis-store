require 'helpers'
require 'redis'
require 'securerandom'

# These tests exercise the plugin against a real Redis server, unlike
# test/plugin/test_out_redis_publish.rb which stubs out the entire Redis
# class and therefore cannot detect a redis-rb client API break (e.g. the
# `pipelined` block-argument change between redis-rb 4.x and 5.x/6.x).
#
# Run a real Redis first:
#   docker run -d --rm -p 6379:6379 redis:7-alpine
# then:
#   bundle exec rake test:integration
class RedisStoreOutputIntegrationTest < Test::Unit::TestCase
  REDIS_HOST = ENV['REDIS_HOST'] || '127.0.0.1'
  REDIS_PORT = (ENV['REDIS_PORT'] || 6379).to_i

  def setup
    Fluent::Test.setup
    @redis = Redis.new(host: REDIS_HOST, port: REDIS_PORT, timeout: 2.0)
    begin
      @redis.ping
    rescue StandardError => e
      omit "no Redis reachable at #{REDIS_HOST}:#{REDIS_PORT} (#{e.class}: #{e.message});" \
        " start one with `docker run -d --rm -p 6379:6379 redis:7-alpine` to run integration tests"
    end
    @key = "fluent-plugin-redis-store-test:#{SecureRandom.hex(8)}"
  end

  def teardown
    @redis.del(@key) if @redis
  end

  def create_driver(conf)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::RedisStoreOutput).configure(conf)
  end

  def get_time
    event_time("2011-01-02 13:14:15 UTC")
  end

  def test_zset_batches_many_records_through_one_pipeline
    config = %[
      host       #{REDIS_HOST}
      port       #{REDIS_PORT}
      store_type  zset
      key         #{@key}
      score_path  result
    ]
    d = create_driver(config)
    d.run(default_tag: 'test') do
      50.times { |i| d.feed(get_time, { 'result' => i }) }
    end

    assert_equal 50, @redis.zcard(@key)
  end

  def test_zset_collision_policy_nx_does_not_overwrite
    @redis.zadd(@key, 1, 'v')
    config = %[
      host             #{REDIS_HOST}
      port             #{REDIS_PORT}
      store_type       zset
      key              #{@key}
      score_path       result
      collision_policy NX
    ]
    d = create_driver(config)
    d.run(default_tag: 'test') do
      d.feed(get_time, { 'result' => 99 })
    end

    assert_equal 1.0, @redis.zscore(@key, 'v')
  end

  def test_zset_value_length_trims_via_lua_eval
    config = %[
      host          #{REDIS_HOST}
      port          #{REDIS_PORT}
      store_type    zset
      key           #{@key}
      score_path    result
      value_length  3
    ]
    d = create_driver(config)
    d.run(default_tag: 'test') do
      10.times { |i| d.feed(get_time, { 'result' => i }) }
    end

    # generate_zremrangebyrank_script removes one more entry than value_length
    # on the 'asc' path (a pre-existing off-by-one, not introduced by the
    # pipeline fix) -- this asserts current behavior, not a spec.
    assert_equal 2, @redis.zcard(@key)
  end

  def test_list_rpush_asc
    config = %[
      host        #{REDIS_HOST}
      port        #{REDIS_PORT}
      format_type plain
      store_type  list
      key         #{@key}
      value_path  v
    ]
    d = create_driver(config)
    d.run(default_tag: 'test') do
      5.times { |i| d.feed(get_time, { 'v' => i.to_s }) }
    end

    assert_equal 5, @redis.llen(@key)
    assert_equal %w[0 1 2 3 4], @redis.lrange(@key, 0, -1)
  end

  def test_set_sadd
    config = %[
      host        #{REDIS_HOST}
      port        #{REDIS_PORT}
      format_type plain
      store_type  set
      key         #{@key}
      value_path  v
    ]
    d = create_driver(config)
    d.run(default_tag: 'test') do
      3.times { |i| d.feed(get_time, { 'v' => "member-#{i}" }) }
    end

    assert_equal 3, @redis.scard(@key)
    assert_equal true, @redis.sismember(@key, 'member-1')
  end

  def test_string_set_and_key_expire
    config = %[
      host        #{REDIS_HOST}
      port        #{REDIS_PORT}
      format_type plain
      store_type  string
      key         #{@key}
      value_path  v
      key_expire  30
    ]
    d = create_driver(config)
    d.run(default_tag: 'test') do
      d.feed(get_time, { 'v' => 'hello' })
    end

    assert_equal 'hello', @redis.get(@key)
    ttl = @redis.ttl(@key)
    assert ttl > 0 && ttl <= 30, "expected 0 < ttl <= 30, got #{ttl}"
  end
end
