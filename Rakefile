# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"
require "minitest/test_task"

Rake::ExtensionTask.new("string_view") do |ext|
  ext.lib_dir = "lib/string_view"
end

Minitest::TestTask.create do |t|
  t.test_prelude = %(require "rake"; Rake::Task["compile"].invoke)
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[test rubocop]
