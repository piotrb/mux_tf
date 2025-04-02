# frozen_string_literal: true

require "yaml/store"

# Ruby 2.7's YAML doesn't have a :unsafe_load method .. so we skip all that
# if YAML.singleton_methods.include?(:unsafe_load)
#   module YAML
#     # Explaination from @h4xnoodle:
#     #
#     # Since ruby 3+ and psych 4+, the yaml loading became extra safe so the
#     # expired_at timestamp in the yaml cache is no longer parsing for whatever reason.
#     #
#     # Attempts were made with
#     #
#     # `@store = YAML::Store.new path`
#     # =>
#     # `@store = YAML::Store.new(path, { aliases: true, permitted_classes: [Time] })`
#     # to get it to work but that didn't help, so decided to just bypass the safe
#     # loading, since the file is controlled by us for the version checking.
#     #
#     # This is to override the way that psych seems to be loading YAML.
#     # Instead of using 'load' which needs work to permit the 'Time' class
#     # (which from above I tried that and it wasn't working so I decided to just
#     # bypass and use what it was doing before).
#     # This brings us back to the equivalent that was working before in that unsafe
#     # load was used before the psych upgrade.
#     #
#     # This change: https://my.diffend.io/gems/psych/3.3.2/4.0.0
#     # is the changes that 'cause the problem' and so I'm 'fixing it' by using the old equivalent.
#     #
#     # Maybe the yaml cache needs more work to have
#     # `YAML::Store.new(path, { aliases: true, permitted_classes: [Time] }) work.`
#     #
#     class << self
#       undef load # avoid a warning about the next line redefining load
#       alias load unsafe_load
#     end
#   end
# end

module MuxTf
  class UnsafeYamlStore < YAML::Store
    def initialize( *o )
      super(*o)
      @opt[:permitted_classes] ||= [Symbol]
    end

    # basically have to override the whole load method, since it doesn't allow customization of the allowed classes .. 
    def load(content)
      table = YAML.safe_load(content, **@opt)
      if table == false || table == nil
        {}
      else
        table
      end
    end
  end

  class YamlCache
    def initialize(path, default_ttl:)
      @default_ttl = default_ttl
      @store = UnsafeYamlStore.new path, { aliases: true, permitted_classes: [Symbol, Time] }   
    end

    def set(key, value, ttl: @default_ttl)
      @store.transaction do
        @store[key] = {
          expires_at: Time.now + ttl,
          value: value
        }
      end
    end

    def fetch(key, ttl: @default_ttl)
      info = nil
      @store.transaction(true) do
        info = @store[key]
      end

      if info.nil? || info[:expires_at] < Time.now
        raise KeyError, info.nil? ? "no value at key: #{key}" : "value expired at key: #{key}" unless block_given?

        value = yield
        set(key, value, ttl: ttl)
        return value

      end

      info[:value]
    end
  end
end
