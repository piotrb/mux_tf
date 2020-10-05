require "yaml/store"

module MuxTf
  class YamlCache
    def initialize(path, default_ttl:)
      @default_ttl = default_ttl
      @store = YAML::Store.new path
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
        if block_given?
          value = yield
          set(key, value, ttl: ttl)
          return value
        else
          raise KeyError, info.nil? ? "no value at key: #{key}" : "value expired at key: #{key}"
        end
      end

      info[:value]
    end
  end
end
