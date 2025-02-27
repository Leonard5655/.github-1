#!/usr/bin/env ruby
# frozen_string_literal: true

require "English"
require "fileutils"
require "open3"
require "pathname"
require "yaml"

# This makes sense for a standalone script.
# rubocop:disable Style/TopLevelMethodDefinition
def git(*args)
  system "git", *args
  exit $CHILD_STATUS.exitstatus unless $CHILD_STATUS.success?
end
# rubocop:enable Style/TopLevelMethodDefinition

target_directory = ARGV.fetch(0, "")
target_directory_path = Pathname(target_directory)
repository_name = target_directory_path.basename.to_s
homebrew_repository_path = Pathname(ARGV.fetch(1, ""))

if !target_directory_path.directory? || !homebrew_repository_path.directory? || ARGV[2]
  abort "Usage: #{$PROGRAM_NAME} <target_directory_path> <homebrew_repository_path>"
end

ruby_version = ".ruby-version"
rubocop_yml = ".rubocop.yml"
dependabot_yml = ".github/dependabot.yml"

homebrew_ruby_version =
  (homebrew_repository_path/"Library/Homebrew/vendor/portable-ruby-version").read
                                                                            .chomp
                                                                            .sub(/_\d+$/, "")
homebrew_rubocop_config_yaml = YAML.load_file(
  homebrew_repository_path/"Library/#{rubocop_yml}",
  permitted_classes: [Symbol, Regexp],
)
homebrew_rubocop_config = homebrew_rubocop_config_yaml.reject do |key, _|
  key.match?(%r{\Arequire|inherit_from|inherit_mode|Cask/|Formula|Homebrew|Performance/|RSpec|Sorbet/})
end.to_yaml

custom_ruby_version_repos = %w[
  mass-bottling-tracker-private
].freeze
custom_rubocop_repos = %w[
  ci-orchestrator
  mass-bottling-tracker-private
  orka_api_client
  ruby-macho
].freeze
custom_dependabot_repos = %w[
  brew
  brew-pip-audit
  ci-orchestrator
].freeze

puts "Detecting changes…"
[
  ruby_version,
  rubocop_yml,
  dependabot_yml,
  ".github/workflows/lock-threads.yml",
  ".github/workflows/stale-issues.yml",
].each do |file|
  target_path = target_directory_path/file
  target_path.dirname.mkpath

  case file
  when ruby_version
    next if custom_ruby_version_repos.include?(repository_name)

    target_path.write("#{homebrew_ruby_version}\n")
  when rubocop_yml
    next if custom_rubocop_repos.include?(repository_name)

    FileUtils.rm_f target_path
    target_path.write(
      "# This file is synced from `Homebrew/brew` by the `.github` repository, do not modify it directly.\n" \
      "#{homebrew_rubocop_config}\n",
    )
  when dependabot_yml
    next if custom_dependabot_repos.include?(repository_name)
    next if file == target_path.to_s

    FileUtils.cp file, target_path
  else
    next if file == target_path.to_s

    FileUtils.cp file, target_path
  end
end

out, err, status = Open3.capture3("git", "-C", target_directory, "status", "--porcelain", "--ignore-submodules=dirty")
raise err unless status.success?

target_directory_path_changed = !out.chomp.empty?

unless target_directory_path_changed
  puts "No changes detected."
  exit
end

git "-C", target_directory, "add", "--all"

out, err, status = Open3.capture3("git", "-C", target_directory, "diff", "--name-only", "--staged")
raise err unless status.success?

modified_paths = out.lines.map(&:chomp)

modified_paths.each do |modified_path|
  puts "Detected changes to #{modified_path}."
  git "-C", target_directory, "commit", modified_path, "--message",
      "#{File.basename(modified_path)}: update to match main configuration", "--quiet"
end
puts

if ENV["GITHUB_ACTIONS"]
  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |f|
    f.puts "pull_request=true"
  end
end
