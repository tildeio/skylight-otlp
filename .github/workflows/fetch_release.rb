#!/usr/bin/env ruby

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'octokit'
end

require 'json'
require 'fileutils'
require 'uri'
require 'net/http'
require 'digest/sha2'

root = File.expand_path('../..', __dir__)

Dir.chdir(root)
CONFIG = JSON.parse(File.read('skylight.json'))
VERSION = CONFIG.fetch('version')
CHECKSUMS = CONFIG.fetch('otlp_checksums')
BASE_URL = 'https://s3.amazonaws.com/skylight-agent-packages/skylight-native'.freeze
REPO = 'tildeio/skylight-otlp'
TOKEN = ENV.fetch('GITHUB_TOKEN')

def download_artifact(platform:, checksum:, version: VERSION, base_url: BASE_URL)
  filename = "skylight_otlp_#{platform}.tar.gz"
  output_filename = filename.sub('skylight_otlp', "skylight_#{version}")
  path = File.join("artifacts/#{output_filename}")
  FileUtils.mkdir_p(File.dirname(path))

  uri = URI("#{base_url}/#{version}/#{filename}")
  digest = Digest::SHA2.new
  puts "fetching Skylight for OTLP; platform=#{platform}"

  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    request = Net::HTTP::Get.new uri
    http.request request do |response|
      raise response.code unless response.code == '200'

      File.open(path, 'wb') do |f|
        response.read_body do |chunk|
          digest << chunk
          f.write(chunk)
        end
      end
    end
  end

  fetched_checksum = digest.hexdigest

  return if checksum == fetched_checksum

  raise "non-matching checksum (expected = #{checksum}; actual = #{fetched_checksum} for #{platform}"
end

CHECKSUMS.each do |platform, checksum|
  download_artifact(platform: platform, checksum: checksum)
end

octokit = Octokit::Client.new(access_token: TOKEN)
puts 'creating release...'
release = octokit.create_release(REPO, VERSION,
                                 name: "Skylight for OTLP #{VERSION}", target_commitish: 'main', draft: true, prerelease: true)

puts "Release id #{release.id} tagged #{VERSION} (#{release.url})"

Dir['artifacts/*'].each do |file|
  puts "uploading #{file}..."
  asset = octokit.upload_asset(release.url, file, content_type: 'application/gzip')
  puts asset.url
end
