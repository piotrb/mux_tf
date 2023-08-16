# frozen_string_literal: true

require "bundler/inline"

dep_def = proc do
  gemspec(path: File.join(__dir__, ".."))
end

begin
  gemfile(&dep_def)
rescue Bundler::GemNotFound
  gemfile(true) do
    source "https://rubygems.org"
    instance_exec(&dep_def)
  end
end
