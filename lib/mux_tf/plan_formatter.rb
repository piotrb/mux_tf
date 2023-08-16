# frozen_string_literal: true

module MuxTf
  class PlanFormatter
    extend TerraformHelpers
    extend PiotrbCliUtils::Util

    class << self
      def log_unhandled_line(state, line, reason: nil)
        pastel = Pastel.new
        p [state, pastel.strip(line), reason]
      end

      def pretty_plan(filename, targets: []) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        pastel = Pastel.new

        meta = {}

        parser = StatefulParser.new(normalizer: pastel.method(:strip))
        parser.state(:info, /^Acquiring state lock/)
        parser.state(:error, /(Error locking state|Error:)/, [:none, :blank, :info, :reading])
        parser.state(:reading, /: (Reading...|Read complete after)/, [:none, :info, :reading])
        parser.state(:none, /^$/, [:reading])
        parser.state(:refreshing, /^.+: Refreshing state... \[id=/, [:none, :info, :reading])
        parser.state(:refreshing, /Refreshing Terraform state in-memory prior to plan.../,
                     [:none, :blank, :info, :reading])
        parser.state(:none, /^----------+$/, [:refreshing])
        parser.state(:none, /^$/, [:refreshing])

        parser.state(:output_info, /^Changes to Outputs:$/, [:none])
        parser.state(:none, /^$/, [:output_info])

        parser.state(:plan_info, /Terraform will perform the following actions:/, [:none])
        parser.state(:plan_summary, /^Plan:/, [:plan_info])

        parser.state(:plan_legend, /^Terraform used the selected providers to generate the following execution$/)
        parser.state(:none, /^$/, [:plan_legend])

        parser.state(:plan_info, /Terraform planned the following actions, but then encountered a problem:/, [:none])

        parser.state(:plan_error, /Planning failed. Terraform encountered an error while generating this plan./, [:refreshing])

        # this extends the error block to include the lock info
        parser.state(:error_lock_info, /Lock Info/, [:error_block_error])
        parser.state(:after_error, /^╵/, [:error_lock_info])

        setup_error_handling(parser, from_states: [:plan_error, :none, :blank, :info, :reading, :plan_summary, :refreshing])

        last_state = nil

        status = tf_plan(out: filename, detailed_exitcode: true, compact_warnings: true, targets: targets) { |raw_line|
          parser.parse(raw_line.rstrip) do |state, line|
            first_in_state = last_state != state

            case state
            when :none
              if line.blank?
                # nothing
              else
                log_unhandled_line(state, line, reason: "unexpected non blank line in :none state")
              end
            when :reading
              clean_line = pastel.strip(line)
              if clean_line.match(/^(.+): Reading...$/)
                log "Reading: #{$LAST_MATCH_INFO[1]} ...", depth: 2
              elsif clean_line.match(/^(.+): Read complete after ([^\[]+)(?: \[(.+)\])?$/)
                if $LAST_MATCH_INFO[3]
                  log "Reading Complete: #{$LAST_MATCH_INFO[1]} after #{$LAST_MATCH_INFO[2]} [#{$LAST_MATCH_INFO[3]}]", depth: 3
                else
                  log "Reading Complete: #{$LAST_MATCH_INFO[1]} after #{$LAST_MATCH_INFO[2]}", depth: 3
                end
              else
                log_unhandled_line(state, line, reason: "unexpected line in :reading state")
              end
            when :info
              if /Acquiring state lock. This may take a few moments.../.match?(line)
                log "Acquiring state lock ...", depth: 2
              else
                log_unhandled_line(state, line, reason: "unexpected line in :info state")
              end
            when :plan_error
              case pastel.strip(line)
              when ""
                # skip empty line
              when /Releasing state lock. This may take a few moments"/
                log line, depth: 2
              when /Planning failed./ # rubocop:disable Lint/DuplicateBranch
                log line, depth: 2
              else
                log_unhandled_line(state, line, reason: "unexpected line in :plan_error state")
              end
            when :error_lock_info
              meta["error"] = "lock"
              meta[$LAST_MATCH_INFO[1]] = $LAST_MATCH_INFO[2] if line =~ /([A-Z]+\S+)+:\s+(.+)$/
              clean_line = pastel.strip(line).gsub(/^│ /, "")
              if clean_line == ""
                meta[:current_error][:body] << clean_line if meta[:current_error][:body].last != ""
              else
                meta[:current_error][:body] << clean_line
              end
            when :refreshing
              if first_in_state
                log "Refreshing state ", depth: 2, newline: false
              else
                print "."
              end
            when :plan_legend
              puts if first_in_state
              log line, depth: 2
            when :refresh_done
              puts if first_in_state
            when :plan_info # rubocop:disable Lint/DuplicateBranch
              puts if first_in_state
              log line, depth: 2
            when :output_info # rubocop:disable Lint/DuplicateBranch
              puts if first_in_state
              log line, depth: 2
            when :plan_summary
              log line, depth: 2
            else
              log_unhandled_line(state, line, reason: "unexpected state") unless handle_error_states(meta, state, line)
            end
            last_state = state
          end
        }
        [status.status, meta]
      end

      def init_status_to_remedies(status, meta)
        remedies = Set.new
        if status != 0
          remedies << :reconfigure if meta[:need_reconfigure]
          meta[:errors].each do |error|
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

      def setup_error_handling(parser, from_states:)
        parser.state(:error_block, /^╷/, from_states | [:after_error])
        parser.state(:error_block_error, /^│ Error: /, [:error_block])
        parser.state(:error_block_warning, /^│ Warning: /, [:error_block])
        parser.state(:after_error, /^╵/, [:error_block, :error_block_error, :error_block_warning])
      end

      def handle_error_states(meta, state, line) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        pastel = Pastel.new

        case state
        when :error_block
          meta[:current_error] = {
            type: :unknown,
            body: []
          }
        when :error_block_error, :error_block_warning
          clean_line = pastel.strip(line).gsub(/^│ /, "")
          if clean_line =~ /^(Warning|Error): (.+)$/
            meta[:current_error][:type] = $LAST_MATCH_INFO[1].downcase.to_sym
            meta[:current_error][:message] = $LAST_MATCH_INFO[2]
          elsif clean_line == ""
            # skip double empty lines
            meta[:current_error][:body] << clean_line if meta[:current_error][:body].last != ""
          else
            meta[:current_error][:body] ||= []
            meta[:current_error][:body] << clean_line
          end
        when :after_error
          case pastel.strip(line)
          when "╵" # closing of an error block
            if meta[:current_error][:type] == :error
              meta[:errors] ||= []
              meta[:errors] << meta[:current_error]
            end
            if meta[:current_error][:type] == :warning
              meta[:warnings] ||= []
              meta[:warnings] << meta[:current_error]
            end
            meta.delete(:current_error)
          end
        else
          return false
        end
        true
      end

      def run_tf_init(upgrade: nil, reconfigure: nil) # rubocop:disable Metrics/MethodLength
        pastel = Pastel.new

        phase = :init

        meta = {}

        parser = StatefulParser.new(normalizer: pastel.method(:strip))

        parser.state(:modules_init, /^Initializing modules\.\.\./, [:none, :backend])
        parser.state(:modules_upgrade, /^Upgrading modules\.\.\./)
        parser.state(:backend, /^Initializing the backend\.\.\./, [:none, :modules_init, :modules_upgrade])
        parser.state(:plugins, /^Initializing provider plugins\.\.\./, [:backend, :modules_init])

        parser.state(:plugin_warnings, /^$/, [:plugins])
        parser.state(:backend_error, /Error:/, [:backend])

        setup_error_handling(parser, from_states: [:plugins])

        status = tf_init(upgrade: upgrade, reconfigure: reconfigure) { |raw_line|
          stripped_line = pastel.strip(raw_line.rstrip)

          parser.parse(raw_line.rstrip) do |state, line|
            case state
            when :modules_init
              if phase != state
                phase = state
                log "Initializing modules ", depth: 1
                next
              end
              case stripped_line
              when /^Downloading (?<repo>[^ ]+) (?<version>[^ ]+) for (?<module>[^ ]+)\.\.\./
                print "D"
              when /^Downloading (?<repo>[^ ]+) for (?<module>[^ ]+)\.\.\./ # rubocop:disable Lint/DuplicateBranch
                print "D"
              when /^- (?<module>[^ ]+) in (?<path>.+)$/
                print "."
              when ""
                puts
              else
                log_unhandled_line(state, line, reason: "unexpected line in :modules_init state")
              end
            when :modules_upgrade
              if phase != state
                # first line
                phase = state
                log "Upgrding modules ", depth: 1, newline: false
                next
              end
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
            when :backend
              if phase != state
                # first line
                phase = state
                log "Initializing the backend ", depth: 1 # , newline: false
                next
              end
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
            when :backend_error
              if raw_line.match "terraform init -reconfigure"
                meta[:need_reconfigure] = true
                log Paint["module needs to be reconfigured", :red], depth: 2
              end
            when :plugins
              if phase != state
                # first line
                phase = state
                log "Initializing provider plugins ...", depth: 1
                next
              end
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
              when /^- Installed (?<module>[^ ]+) v(?<version>.+) \(signed by(?: a)? (?<signed>.+)\)$/
                info = $LAST_MATCH_INFO.named_captures
                log "- [INSTALLED] #{info['module']} v#{info['version']} (#{info['signed']})", depth: 2
              when /^- Using previously-installed (?<module>[^ ]+) v(?<version>.+)$/
                info = $LAST_MATCH_INFO.named_captures
                log "- [USING] #{info['module']} v#{info['version']}", depth: 2
              when /^- Downloading plugin for provider "(?<provider>[^"]+)" \((?<provider_path>[^)]+)\) (?<version>.+)\.\.\.$/
                info = $LAST_MATCH_INFO.named_captures
                log "- #{info['provider']} #{info['version']}", depth: 2
              when "- Checking for available provider plugins..."
                # noop
              else
                log_unhandled_line(state, line, reason: "unexpected line in :plugins state")
              end
            when :plugin_warnings
              if phase != state
                # first line
                phase = state
                next
              end

              log Paint[line, :yellow], depth: 1
            when :none
              next if line == ""

              log_unhandled_line(state, line, reason: "unexpected line in :none state")
            else
              log_unhandled_line(state, line, reason: "unexpected state") unless handle_error_states(meta, state, line)
            end
          end
        }

        [status.status, meta]
      end

      def print_validation_errors(info) # rubocop:disable Metrics/AbcSize
        return unless (info["error_count"]).positive? || (info["warning_count"]).positive?

        log "Encountered #{Paint[info['error_count'], :red]} Errors and #{Paint[info['warning_count'], :yellow]} Warnings!", depth: 2
        info["diagnostics"].each do |dinfo|
          item_handled = false
          color = dinfo["severity"] == "error" ? :red : :yellow
          log "#{Paint[dinfo['severity'].capitalize, color]}: #{dinfo['summary']}", depth: 3
          log dinfo["detail"], depth: 4 if dinfo["detail"]
          log format_validation_range(dinfo["range"], color), depth: 4 if dinfo["range"]
        end
      end

      def process_validation(info) # rubocop:disable Metrics/CyclomaticComplexity
        remedies = Set.new

        if (info["error_count"]).positive? || (info["warning_count"]).positive?
          info["diagnostics"].each do |dinfo|
            item_handled = false

            case dinfo["summary"]
            when /there is no package for .+ cached in/,
                /Missing required provider/,
                /Module not installed/,
                /Module source has changed/,
                /Required plugins are not installed/
              remedies << :init
              item_handled = true
            when /Missing required argument/,
                /Error in function call/,
                /Invalid value for input variable/,
                /Unsupported block type/
              remedies << :user_error
              item_handled = true
            end

            case dinfo["detail"]
            when /timeout while waiting for plugin to start/
              remedies << :init
              item_handled = true
            end

            remedies << :unknown if !item_handled && (dinfo["severity"] == "error")
          end
        end

        remedies
      end

      private

      def format_validation_range(range, color) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
        # filename: "../../../modules/pods/jane_pod/main.tf"
        # start:
        #   line: 151
        #   column: 27
        #   byte: 6632
        # end:
        #   line: 151
        #   column: 53
        #   byte: 6658

        context_lines = 3

        lines = range["start"]["line"]..range["end"]["line"]
        columns = range["start"]["column"]..range["end"]["column"]

        # on ../../../modules/pods/jane_pod/main.tf line 151, in module "jane":
        # 151:   jane_resources_preset = var.jane_resources_presetx
        output = []
        lines_info = if lines.size == 1
                       "#{lines.first}:#{columns.first}"
                     else
                       "#{lines.first}:#{columns.first} to #{lines.last}:#{columns.last}"
                     end
        output << "on: #{range['filename']} line#{lines.size > 1 ? 's' : ''}: #{lines_info}"

        if File.exist?(range["filename"])
          file_lines = File.read(range["filename"]).split("\n")
          extract_range = (([lines.first - context_lines,
                             0].max)..([lines.last + context_lines, file_lines.length - 1].min))
          file_lines.each_with_index do |line, index|
            if extract_range.cover?(index + 1)
              if lines.cover?(index + 1)
                start_col = 1
                end_col = :max
                if index + 1 == lines.first
                  start_col = columns.first
                elsif index + 1 == lines.last
                  start_col = columns.last
                end
                painted_line = paint_line(line, color, start_col: start_col, end_col: end_col)
                output << "#{Paint['>', color]} #{index + 1}: #{painted_line}"
              else
                output << "  #{index + 1}: #{line}"
              end
            end
          end
        end

        output
      end

      def paint_line(line, *paint_options, start_col: 1, end_col: :max)
        end_col = line.length if end_col == :max
        prefix = line[0, start_col - 1]
        suffix = line[end_col..]
        middle = line[start_col - 1..end_col - 1]
        "#{prefix}#{Paint[middle, *paint_options]}#{suffix}"
      end
    end
  end
end
