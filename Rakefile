# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

desc "Run RuboCop"
task :rubocop do
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
end

class NonVerboseRaskTask < RSpec::Core::RakeTask
  def initialize(*args, &task_block)
    super
    @verbose = false
  end
end

NonVerboseRaskTask.new(:rspec)

task default: [:rubocop, :rspec]
