#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'uri'
require 'net/http'
require 'digest/sha2'
require 'octokit'
require 'aws-sdk-lambda'

root = File.expand_path('../..', __dir__)

Dir.chdir(root)
CONFIG = JSON.parse(File.read('skylight.json'))
VERSION = CONFIG.fetch('version')
CHECKSUMS = CONFIG.fetch('otlp_checksums')
BASE_URL = 'https://s3.amazonaws.com/skylight-agent-packages/skylight-native'
REPO = 'tildeio/skylight-otlp'
TOKEN = ENV.fetch('GITHUB_TOKEN')

ENV['AWS_REGION'] ||= 'us-east-1'

REGIONS = %w[
  us-east-1
  eu-west-2
]

class Artifact
  def initialize(checksum:, path:, platform:)
    @checksum = checksum
    @path = path
    @platform = platform
  end

  def upload_github_asset(octokit, release)
    puts "uploading #{@path}..."
    asset = octokit.upload_asset(
      release.url,
      @path,
      content_type: 'application/gzip',
      query: { label: @platform }
    )
    puts asset.url
  end

  def upload_lambda_layer(aws_clients)
    return unless (lambda_arch = LAMBDA_PLATFORMS[@platform])

    require 'zip'
    require 'rubygems/package'
    require 'zlib'

    zipfile_path = "extension_#{lambda_arch}.zip"
    binary_dir = "extensions/#{lambda_arch}"

    FileUtils.rm_rf(zipfile_path)
    FileUtils.rm_rf(@platform)
    FileUtils.rm_rf(binary_dir)

    FileUtils.mkdir_p(binary_dir)

    # 1 - unarchive
    Gem::Package.new('').extract_tar_gz(File.open(@path, 'rb'), binary_dir)

    list = Dir[File.join(binary_dir, '*')]

    if list != [File.join(binary_dir, 'skylight')]
      raise "expected to find one skylight binary but found #{list.inspect}"
    end

    # 2 - make lambda layer zip file
    Zip::File.open(zipfile_path, Zip::File::CREATE) do |zip|
      zip.add('extensions/skylight', list[0])
    end

    aws_clients.each do |client|

      # 3 - make lambda layer
      resp = client.publish_layer_version({
        compatible_architectures: [lambda_arch],
        content: {
          zip_file: File.open(zipfile_path, 'rb')
        }, 
        description: "Skylight #{VERSION}", 
        layer_name: "skylight-#{VERSION}-#{lambda_arch}".tr('.', '_'), 
        license_info: "MIT"
      })

      layer_arn = resp.layer_arn
      layer_version_arn = resp.layer_version_arn
      layer_version = resp.version

      permission_resp = client.add_layer_version_permission({
        action: "lambda:GetLayerVersion", 
        layer_name: layer_arn, 
        principal: "*", 
        statement_id: "permission-#{VERSION}".tr('.', '_'), 
        version_number: layer_version, 
      })

      layer_version_arns << layer_version_arn
    end
  end

  def layer_version_arns
    @layer_version_arns ||= []
  end
end

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

  return Artifact.new(checksum: checksum, path: path, platform: platform) if checksum == fetched_checksum

  raise "non-matching checksum (expected = #{checksum}; actual = #{fetched_checksum} for #{platform}"
end

artifacts = []

CHECKSUMS.each do |platform, checksum|
  artifacts << download_artifact(platform: platform, checksum: checksum)
end

LAMBDA_PLATFORMS = { 'x86_64-linux' => 'x86_64', 'aarch64-linux' => 'arm64' }.freeze

aws = REGIONS.map do |region| 
  Aws::Lambda::Client.new(region: region)
end
# do this first to get the ARNs
artifacts.each do |artifact|
  artifact.upload_lambda_layer(aws)
end

octokit = Octokit::Client.new(access_token: TOKEN)
puts 'creating release...'
release = octokit.create_release(
  REPO,
  VERSION,
  name: "Skylight for OTLP #{VERSION}",
  target_commitish: 'main',
  draft: true,
  prerelease: true,
  # TODO: better formatting
  body: artifacts.map(&:layer_version_arns).flatten.join("\n")
)

puts "Release id #{release.id} tagged #{VERSION} (#{release.url})"

artifacts.each do |artifact|
  artifact.upload_github_asset(octokit, release)
end
