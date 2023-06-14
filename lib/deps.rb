# frozen_string_literal: true

require "bundler/inline"

gemfile do
  gemspec(path: File.join(__dir__, ".."))
end
