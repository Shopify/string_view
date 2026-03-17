# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"

Rake::ExtensionTask.new("string_view") do |ext|
  ext.lib_dir = "lib/string_view"
end

task :test do
  sh "ruby -Ilib -Itest test/test_string_view.rb"
end

# Compile the extension before running tests
task test: :compile

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: :test
