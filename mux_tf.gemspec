# frozen_string_literal: true

require_relative 'lib/mux_tf/version'

Gem::Specification.new do |spec|
  spec.name          = 'mux_tf'
  spec.version       = MuxTf::VERSION
  spec.authors       = ['Piotr Banasik']
  spec.email         = ['piotr@jane.app']

  spec.summary       = 'Terraform Multiplexing Scripts'
  # spec.description   = 'TODO: Write a longer description or delete this line.'
  spec.homepage      = 'https://github.com/piotrb/mux_tf'
  spec.license       = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>= 2.3.0')

  spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  # spec.metadata['changelog_uri'] = "TODO: Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'activesupport'
  spec.add_dependency 'dotenv'
  spec.add_dependency 'paint'
  spec.add_dependency 'pastel'
  spec.add_dependency 'piotrb_cli_utils', '~> 0.1.0'
  spec.add_dependency 'stateful_parser', '~> 0.1.1'
  spec.add_dependency 'tty-prompt'
  spec.add_dependency 'tty-table'
end
