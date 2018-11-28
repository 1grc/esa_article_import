require 'bundler/setup'
require 'esa'
require 'pp'

module Config
  FILE_PATH = './exported_from_esa_team.yaml'.freeze
  ACCESS_TOKEN = ''.freeze # read/write対応
  PAST_TEAM = ''.freeze # 移行元チーム名(サブドメイン)
  CURRENT_TEAM = ''.freeze # 移行先チーム名(サブドメイン)
end

module Common
  require 'yaml'

  # retry
  def wait_for(seconds)
    (seconds / 10).times do
      print '.'
      sleep 10
    end
    puts
  end
end

class Exporter
  include Common
  include Config

  attr_reader :client, :per_page

  def initialize(access_token:, current_team:)
    @client = Esa::Client.new(
      access_token: access_token,
      current_team: current_team
    )
    @per_page = 50
  end

  def self.export(access_token:, current_team:)
    exporter = new(access_token: access_token, current_team: current_team)
    exporter.export
  end

  def export
    return puts "already exist: #{FILE_PATH}" if File.exist?(FILE_PATH)

    res = client.posts(page: 1, per_page: per_page)
    # postsが取得できなかったときfetchで例外吐いて停止
    posts = res.body.fetch('posts').map { |post| extract_params(post) }
    num = (res.body['total_count'].to_i / res.body['per_page'].to_i) + 1

    (2..num).each do |v|
      posts_frag = client.posts(page: v, per_page: per_page).body.fetch('posts')
      posts << posts_frag.map { |post| extract_params(post) }
    end

    File.open(FILE_PATH, 'w') do |f|
      YAML.dump({ posts: posts }, f)
    end

    puts "created: #{FILE_PATH}"
  end

  private

  def extract_params(post)
    extracted = {
      name: post['name'],
      body_md: post['body_md'],
      tags: post['tags'],
      category: post['category'],
      wip: post['wip'],
      message: post['message'],
      user: post.dig('created_by', 'screen_name')
    }
    extracted
  end
end

class Importer
  include Common
  include Config

  attr_reader :client

  def initialize(access_token:, current_team:)
    @client = Esa::Client.new(
      access_token: access_token,
      current_team: current_team
    )
  end

  def self.import(access_token:, current_team:)
    importer = new(access_token: access_token, current_team: current_team)
    importer.import
  end

  def import
    posts = YAML.load_file(FILE_PATH)
    posts[:posts].each do |post|
      create(post: post)
    end
  end

  def create(post:, retried: false)
    res = client.create_post(post)

    case res.status
    when 201
      puts "created: #{res.body['full_name']}"
      File.open('./log.txt', 'w+') do |f|
        f.puts post
      end
    when 404
      puts "#{res.status} #{res.body['message']}"
      exit 1 if retried

      post[:user] = 'esa_bot'
      create(post: post, retried: true)
    when 429
      retry_after = (res.headers['Retry-After'] || 20 * 60).to_i
      puts "rate limit exceeded: will retry after #{retry_after} seconds."
      wait_for(retry_after)
      create(post: post, retried: true)
    else
      puts "failure with status: #{res.status}"
      exit 1
    end
  end
end

Exporter.export(access_token: Config::ACCESS_TOKEN, current_team: Config::PAST_TEAM)
Importer.import(access_token: Config::ACCESS_TOKEN, current_team: Config::CURRENT_TEAM)