# frozen_string_literal: true

require "English"
module MuxTf
  class StderrLineHandler
    include PiotrbCliUtils::Util
    include Coloring

    include ErrorHandlingMethods

    attr_reader :meta

    def initialize(operation: nil)
      @operation = operation
      @held_messages = []
      @parser = StatefulParser.new(normalizer: pastel.method(:strip))
      @meta = {}
      setup_error_handling(@parser, from_states: [:none])
    end

    def transform_paths!(hash, key)
      return unless hash[key]

      hash[key].strip!.gsub!(/^\[/, "").gsub!(/\]$/, "") if key == "prefix"

      hash[key].gsub!("#{Dir.getwd}/", "")
      hash[key].gsub!(Dir.getwd, "")

      hash[key].gsub!($LAST_MATCH_INFO[1], "<cache>/") if hash[key].match(%r{(\.terragrunt-cache/[^/]+/[^/]+/)})

      hash
    end

    def handle(raw_line)
      return if raw_line.strip.empty?

      if raw_line =~ /Error when retrieving token from sso: Token has expired and refresh failed/
        log "#{pastel.red('error')}: SSO Session expired.", depth: 2
        return
      end

      # [✘] error when retrieving credentials from custom process. please login using 'granted sso login --sso-start-url https://janeapp.awsapps.com/start --sso-region us-east-1'
      if raw_line =~ /error when retrieving credentials from custom process. please login using '([^']+)'/
        unless @sso_expired
          @sso_expired = true
          log "#{pastel.red('error')}: SSO Session expired.", depth: 2
          log "#{pastel.red('error')}: Run: #{$LAST_MATCH_INFO[1]}", depth: 2
        end
        return
      end

      if raw_line.strip[0] == "{" && raw_line.strip[-1] == "}"
        begin
          # assuming that stderr is JSON and TG logs
          parsed_line = JSON.parse(raw_line)
          transform_paths!(parsed_line, "msg")
          transform_paths!(parsed_line, "prefix")
          parsed_line["msg"].gsub!("#{Dir.getwd}/", "")
          parsed_line["prefix"]&.strip!&.gsub!(/^\[/, "")&.gsub!(/\]$/, "")
          parsed_line["prefix"]&.gsub!(Dir.getwd, "")
          if @operation == :plan
            handle_plan_json(parsed_line)
          else
            log format_tg_log_line(parsed_line), depth: 2
          end
        rescue JSON::ParserError => e
          log "#{pastel.red('error')}: failed to parse JSON: #{e.message}", depth: 2
          log raw_line.rstrip, depth: 2
        end
      else
        @parser.parse(raw_line.rstrip) do |state, line|
          # log raw_line.rstrip, depth: 2
          log_unhandled_line(state, line, reason: "unexpected state in StderrLineHandler") unless handle_error_states(@meta, state, line)
        end
      end
    end

    def handle_plan_json(parsed_line)
      if parsed_line["msg"] =~ /terraform invocation failed in/
        @held_messages << format_tg_log_line(parsed_line)
      elsif parsed_line["msg"] =~ /1 error occurred/ && parsed_line["msg"] =~ /exit status 2\n/
        # 2 = Succeeded with non-empty diff (changes present)
        # clear the held messages and swallow up this message too
        @held_messages = []
      else
        # flush
        log format_tg_log_line(parsed_line), depth: 2
      end
    end

    def flush
      @held_messages.each do |msg|
        log msg, depth: 2
      end
      @held_messages = []
    end

    def do_print_errors
      print_errors(@meta) if @meta[:errors] && !@meta[:errors].empty?
    end

    def merge_meta_into(other_meta)
      [:errors, :warnings].each do |type|
        if @meta[type]
          other_meta[type] ||= []
          other_meta[type] += @meta[type]
        end
      end

      extra_keys = @meta.keys - [:errors, :warnings]
      return unless extra_keys.any?

      log "Unhandled keys in stderr_handler.meta: #{extra_keys.inspect}"
      log @meta.inspect
    end

    private

    def format_tg_log_line(line_data)
      # {
      #   "level"=>"error",
      #   "msg"=>"terraform invocation failed in /Users/piotr/Work/janepods/accounts/eks-dev/unstable-1/kluster/.terragrunt-cache/Gqer3b7TGI4swB-Nw7Pe5DUIrus/JkQqfrQedXyGMwcl4yYfGocMcvk/modules/kluster",
      #   "prefix"=>"[/Users/piotr/Work/janepods/accounts/eks-dev/unstable-1/kluster] ",
      #   "time"=>"2024-02-28T16:14:28-08:00"
      # }

      msg = ""
      msg += case line_data["level"]
             when "info"
               pastel.cyan(line_data["level"])
             when "error"
               pastel.red(line_data["level"])
             else
               pastel.orange(line_data["level"])
             end
      msg += ": #{line_data['msg']}"
      msg += " [#{line_data['prefix']}]" if line_data["prefix"] && !line_data["prefix"].empty?
      msg
    end
  end
end
