# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"
require "minitest/test_task"

Rake::ExtensionTask.new("string_view") do |ext|
  ext.lib_dir = "lib/string_view"
end

Minitest::TestTask.create

# Compile the extension before running tests
task test: :compile

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: [:test, :rubocop]
