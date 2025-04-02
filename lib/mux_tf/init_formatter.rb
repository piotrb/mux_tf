module MuxTf
  class InitFormatter
    extend TerraformHelpers
    extend PiotrbCliUtils::Util
    include Coloring

    extend ErrorHandlingMethods
    extend FormatterCommon

    class << self
      def parse_tf_ui_line(parsed_line, meta, parser, phase:)
        # p(parsed_line)
        case parsed_line[:type]
        when "version"
          meta[:terraform_version] = parsed_line[:terraform] if parsed_line[:terraform]
          meta[:ui_version] = parsed_line[:ui] if parsed_line[:ui]
          meta[:tofu_version] = parsed_line[:tofu] if parsed_line[:tofu]

        when "output", "unknown"
          raw_line = parsed_line[:message]
          stripped_line = pastel.strip(raw_line.rstrip)
          parser.parse(raw_line.rstrip) do |state, line|
            if (handled = handle_init_line(state, line, meta, phase: phase, stripped_line: stripped_line))
              phase = handled[:phase]
            elsif handle_error_states(meta, state, line)
              # no-op
            else
              log_unhandled_line(state, line, reason: "unexpected state")
            end
          end

        else
          print_init_line(parsed_line, from: "parse_tf_ui_line,else")
        end
        phase
      end

      def init_status_to_remedies(status, meta)
        remedies = Set.new
        if status != 0
          remedies << :reconfigure if meta[:need_reconfigure]
          remedies << :auth if meta[:need_auth]
          log "!! expected meta[:errors] to be set, how did we get here?" unless meta[:errors]
          meta[:errors]&.each do |error|
            remedies << :add_provider_constraint if error[:body].grep(/Could not retrieve the list of available versions for provider/)
          end
          if remedies.empty?
            log "!! don't know how to generate init remedies for this"
            log "!! Status: #{status}"
            log "!! Meta:"
            log meta.to_yaml.split("\n").map { |l| "!!   #{l}" }.join("\n")
            remedies << :unknown
          end
        end
        remedies
      end

      def setup_init_parser(parser)
        parser.state(:modules_init, /^Initializing modules\.\.\./, [:none, :backend])
        parser.state(:modules_upgrade, /^Upgrading modules\.\.\./)
        parser.state(:backend, /^Initializing the backend\.\.\./, [:none, :modules_init, :modules_upgrade])
        parser.state(:plugins, /^Initializing provider plugins\.\.\./, [:backend, :modules_init])

        parser.state(:backend_error, /Error when retrieving token from sso/, [:backend])

        parser.state(:plugin_warnings, /^$/, [:plugins])
        parser.state(:backend_error, /Error:/, [:backend])
      end

      def handle_init_line(state, line, meta, phase:, stripped_line:)
        case state
        when :modules_init
          if phase == state
            case stripped_line
            when /^Downloading (?<repo>[^ ]+) (?<version>[^ ]+) for (?<module>[^ ]+)\.\.\./
              print "D"
            when /^Downloading (?<repo>[^ ]+) for (?<module>[^ ]+)\.\.\./ # rubocop:disable Lint/DuplicateBranch
              print "D"
            when /^- (?<module>[^ ]+) in(?: (?<path>.+))?$/
              print "."
            when ""
              puts
            else
              log_unhandled_line(state, line, reason: "unexpected line in :modules_init state")
            end
          else
            phase = state
            log "Initializing modules ", depth: 1
          end
        when :modules_upgrade
          if phase == state
            case stripped_line
            when /^- (?<module>[^ ]+) in (?<path>.+)$/
              print "."
            when /^Downloading (?<repo>[^ ]+) (?<version>[^ ]+) for (?<module>[^ ]+)\.\.\./
              print "D"
            when /^Downloading (?<repo>[^ ]+) for (?<module>[^ ]+)\.\.\./ # rubocop:disable Lint/DuplicateBranch
              print "D"
            when ""
              puts
            else
              log_unhandled_line(state, line, reason: "unexpected line in :modules_upgrade state")
            end
          else
            # first line
            phase = state
            log "Upgrding modules ", depth: 1, newline: false
          end
        when :backend
          if phase == state
            case stripped_line
            when /^Successfully configured/
              log line, depth: 2
            when /unless the backend/ # rubocop:disable Lint/DuplicateBranch
              log line, depth: 2
            when ""
              puts
            else
              log_unhandled_line(state, line, reason: "unexpected line in :backend state")
            end
          else
            # first line
            phase = state
            log "Initializing the backend ", depth: 1 # , newline: false
          end
        when :backend_error
          if raw_line.match "terraform init -reconfigure"
            meta[:need_reconfigure] = true
            log pastel.red("module needs to be reconfigured"), depth: 2
          end
          if raw_line.match "Error when retrieving token from sso"
            meta[:need_auth] = true
            log pastel.red("authentication problem"), depth: 2
          end
        when :plugins
          if phase == state
            case stripped_line
            when /^- Reusing previous version of (?<module>.+) from the dependency lock file$/
              info = $LAST_MATCH_INFO.named_captures
              log "- [FROM-LOCK] #{info['module']}", depth: 2
            when /^- (?<module>.+) is built in to Terraform$/
              info = $LAST_MATCH_INFO.named_captures
              log "- [BUILTIN] #{info['module']}", depth: 2
            when /^- Finding (?<module>[^ ]+) versions matching "(?<version>.+)"\.\.\./
              info = $LAST_MATCH_INFO.named_captures
              log "- [FIND] #{info['module']} matching #{info['version'].inspect}", depth: 2
            when /^- Finding latest version of (?<module>.+)\.\.\.$/
              info = $LAST_MATCH_INFO.named_captures
              log "- [FIND] #{info['module']}", depth: 2
            when /^- Installing (?<module>[^ ]+) v(?<version>.+)\.\.\.$/
              info = $LAST_MATCH_INFO.named_captures
              log "- [INSTALLING] #{info['module']} v#{info['version']}", depth: 2
            when /^- Installed (?<module>[^ ]+) v(?<version>.+) \(signed(?:, | by)(?: a)? (?<signed>.+)\)$/
              info = $LAST_MATCH_INFO.named_captures
              log "- [INSTALLED] #{info['module']} v#{info['version']} (#{info['signed']})", depth: 2
            when /^- Using previously-installed (?<module>[^ ]+) v(?<version>.+)$/
              info = $LAST_MATCH_INFO.named_captures
              log "- [USING] #{info['module']} v#{info['version']}", depth: 2
            when /^- Downloading plugin for provider "(?<provider>[^"]+)" \((?<provider_path>[^)]+)\) (?<version>.+)\.\.\.$/
              info = $LAST_MATCH_INFO.named_captures
              log "- #{info['provider']} #{info['version']}", depth: 2
            when /^- Using (?<provider>[^ ]+) v(?<version>.+) from the shared cache directory$/
              info = $LAST_MATCH_INFO.named_captures
              log "- [CACHE HIT] #{info['provider']} #{info['version']}", depth: 2
            when "- Checking for available provider plugins..."
              # noop
            when %r{^- terraform\.io/builtin/terraform is built in to OpenTofu}
              # noop
            else
              log_unhandled_line(state, line, reason: "unexpected line in :plugins state")
            end
          else
            # first line
            phase = state
            log "Initializing provider plugins ...", depth: 1
          end
        when :plugin_warnings
          if phase == state
            log pastel.yellow(line), depth: 1
          else
            # first line
            phase = state
          end
        when :none
          log_unhandled_line(state, line, reason: "unexpected line in :none state") if line != ""
        else
          return false
          # log_unhandled_line(state, line, reason: "unexpected state") unless handle_error_states(meta, state, line)
        end

        { phase: phase }
      end

      def run_tf_init(upgrade: nil, reconfigure: nil)
        phase = :init
        meta = {}
        meta[:seen] = {
          module_and_type: Set.new
        }

        parser = StatefulParser.new(normalizer: pastel.method(:strip))

        setup_init_parser(parser)

        setup_error_handling(parser, from_states: [:plugins, :modules_init])

        status = tf_init_json(upgrade: upgrade, reconfigure: reconfigure) { |parsed_line|
          # seen = proc { |module_arg, type_arg| meta[:seen][:module_and_type].include?([module_arg, type_arg]) }

          case parsed_line[:level]
          when "info"
            # p parsed_line
            case parsed_line[:module]
            when "terraform.ui", "tofu.ui"
              phase = parse_tf_ui_line(parsed_line, meta, parser, phase: phase)
            else
              print_init_line(parsed_line, from: "run_tf_init_v2,info,else")
            end
          when "error"
            if parsed_line[:diagnostic]
              handled_error = false
              muted_error = false
              current_meta_error = {}
              unless parsed_line[:module] == "terragrunt" && parsed_line[:type] == "tf_failed"
                meta[:errors] ||= []
                current_meta_error = {
                  type: :error,
                  message: parsed_line[:diagnostic]["summary"],
                  body: parsed_line[:diagnostic]["detail"].split("\n")
                }
                meta[:errors] << current_meta_error
              end

              if parsed_line[:diagnostic]["summary"] == "Error acquiring the state lock"
                meta["error"] = "lock"
                meta.merge!(parse_lock_info(parsed_line[:diagnostic]["detail"]))
                handled_error = true
              elsif parsed_line[:module] == "terragrunt" && parsed_line[:type] == "tf_failed"
                muted_error = true
              end

              unless muted_error
                if handled_error
                  print_init_line(parsed_line, without: [:diagnostic], from: "run_tf_init_v2,error,handled")
                else
                  # print_init_line(parsed_line, from: "run_tf_init_v2,error,unhandled_error")
                  print_unhandled_error_line(parsed_line)
                  current_meta_error[:printed] = true
                end
              end
            elsif parsed_line[:message] =~ /^\[reset\]/
              print_unhandled_error_line(parsed_line)
            else
              print_init_line(parsed_line, from: "run_tf_init_v2,error,else")
            end
          end
        }
        [status.status, meta]
      end

      def tf_init_json(upgrade: nil, reconfigure: nil, &block)
        tf_cmd_json(proc { |handler|
          tf_init(upgrade: upgrade, reconfigure: reconfigure, json: true, &handler)
        }, &block)
      end

      def print_init_line(parsed_line, without: [], from: nil)
        default_without = [
          :level,
          :module,
          :type,
          :stream,
          :message,
          :timestamp,
          :terraform,
          :ui
        ]
        extra = parsed_line.without(*default_without, *without)
        data = parsed_line.merge(extra: extra).merge(from: from)
        log_line = [
          "%<from>s",
          "%<level>-6s",
          "%<module>-12s",
          "%<type>-10s",
          "%<message>s",
          "%<extra>s"
        ].map { |format_string|
          field = format_string.match(/%<([^>]+)>/)[1].to_sym
          data[field].present? ? format(format_string, data) : nil
        }.compact.join(" | ")
        log log_line
      end
    end
  end
end
