# frozen_string_literal: true

module MuxTf
  module VersionCheck
    def has_updates? # rubocop:disable Naming/PredicateName
      current_gem_version < latest_gem_version
    end

    def latest_gem_version
      value = cache.fetch("latest_gem_version") {
        fetcher = Gem::SpecFetcher.fetcher
        dependency = Gem::Dependency.new "mux_tf"
        remotes, = fetcher.search_for_dependency dependency
        remotes.map(&:first).map(&:version).max.to_s
      }

      Gem::Version.new(value)
    end

    def current_gem_version
      Gem::Version.new(MuxTf::VERSION)
    end

    def cache
      @cache ||= YamlCache.new(File.expand_path("~/.mux_tf.yaml"), default_ttl: 1.hour)
    end

    module_function :has_updates?, :latest_gem_version, :current_gem_version, :cache
  end
end
