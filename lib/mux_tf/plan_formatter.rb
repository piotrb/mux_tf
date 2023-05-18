# frozen_string_literal: true

module MuxTf
  class PlanFormatter
    extend TerraformHelpers
    extend PiotrbCliUtils::Util

    class << self
      def pretty_plan(filename, targets: [])
        pastel = Pastel.new

        once = OnceHelper.new

        meta = {}

        parser = StatefulParser.new(normalizer: pastel.method(:strip))
        parser.state(:info, /^Acquiring state lock/)
        parser.state(:error, /(╷|Error locking state|Error:)/, %i[none blank info reading])
        parser.state(:reading, /: (Reading...|Read complete after)/, %i[none info reading])
        parser.state(:none, /^$/, [:reading])
        parser.state(:refreshing, /^.+: Refreshing state... \[id=/, %i[none info reading])
        parser.state(:refreshing, /Refreshing Terraform state in-memory prior to plan.../, %i[none blank info reading])
        parser.state(:refresh_done, /^----------+$/, [:refreshing])
        parser.state(:refresh_done, /^$/, [:refreshing])
        parser.state(:plan_info, /Terraform will perform the following actions:/, [:refresh_done, :none])
        parser.state(:plan_summary, /^Plan:/, [:plan_info])

        parser.state(:plan_legend, /^Terraform used the selected providers to generate the following execution$/)
        parser.state(:none, /^$/, [:plan_legend])

        parser.state(:error_lock_info, /Lock Info/, [:error])
        parser.state(:error, /^$/, [:error_lock_info])

        parser.state(:plan_error, /^╷|Error: /, %i[refreshing refresh_done])

        status = tf_plan(out: filename, detailed_exitcode: true, compact_warnings: true, targets: targets) { |raw_line|
          parser.parse(raw_line.rstrip) do |state, line|
            case state
            when :none
              if line.blank?
                # nothing
              else
                p [state, line]
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
                p [state, line]
              end
            when :info
              if /Acquiring state lock. This may take a few moments.../.match?(line)
                log "Acquiring state lock ...", depth: 2
              else
                p [state, line]
              end
            when :error
              meta["error"] = "lock"
              log Paint[line, :red], depth: 2
            when :plan_error
              once.for(state).once { puts }
              meta["error"] = "refresh"
              log Paint[line, :red], depth: 2
            when :error_lock_info
              if line =~ /([A-Z]+[\S]+)+:\s+(.+)$/
                meta[$LAST_MATCH_INFO[1]] = $LAST_MATCH_INFO[2]
              end
              log Paint[line, :red], depth: 2
            when :refreshing
              once.for(state).once {
                log "Refreshing state ", depth: 2, newline: false
              }.otherwise {
                print "."
              }
            when :plan_legend
              once.for(state).once { puts }
              log line, depth: 2
            when :refresh_done
              once.for(state).once {
                puts
              }.otherwise {
                #nothing
              }
            when :plan_info
              once.for(state).once { puts }
              log line, depth: 2
            when :plan_summary
              log line, depth: 2
            else
              p [state, pastel.strip(line)]
            end
          end
        }
        [status.status, meta]
      end

      def init_status_to_remedies(status, meta)
        remedies = Set.new
        if status != 0
          if meta[:need_reconfigure]
            remedies << :reconfigure
          else
            p [status, meta]
            remedies << :unknown
          end
        end
        remedies
      end

      def run_tf_init(upgrade: nil, reconfigure: nil)
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
              when /^Downloading (?<repo>[^ ]+) for (?<module>[^ ]+)\.\.\./
                print "D"
              when /^- (?<module>[^ ]+) in (?<path>.+)$/
                print "."
              when ""
                puts
              else
                p [state, stripped_line]
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
              when /^Downloading (?<repo>[^ ]+) for (?<module>[^ ]+)\.\.\./
                print "D"
              when ""
                puts
              else
                p [state, stripped_line]
              end
            when :backend
              if phase != state
                # first line
                phase = state
                log "Initializing the backend ", depth: 1, newline: false
                next
              end
              case stripped_line
              when /^Successfully configured/
                log line, depth: 2
              when /unless the backend/
                log line, depth: 2
              when ""
                puts
              else
                p [state, stripped_line]
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
                log "- [FROM-LOCK] #{info["module"]}", depth: 2
              when /^- (?<module>.+) is built in to Terraform$/
                info = $LAST_MATCH_INFO.named_captures
                log "- [BUILTIN] #{info["module"]}", depth: 2
              when /^- Finding (?<module>[^ ]+) versions matching "(?<version>.+)"\.\.\./
                info = $LAST_MATCH_INFO.named_captures
                log "- [FIND] #{info["module"]} matching #{info["version"].inspect}", depth: 2
              when /^- Finding latest version of (?<module>.+)\.\.\.$/
                info = $LAST_MATCH_INFO.named_captures
                log "- [FIND] #{info["module"]}", depth: 2
              when /^- Installing (?<module>[^ ]+) v(?<version>.+)\.\.\.$/
                info = $LAST_MATCH_INFO.named_captures
                log "- [INSTALLING] #{info["module"]} v#{info["version"]}", depth: 2
              when /^- Installed (?<module>[^ ]+) v(?<version>.+) \(signed by( a)? (?<signed>.+)\)$/
                info = $LAST_MATCH_INFO.named_captures
                log "- [INSTALLED] #{info["module"]} v#{info["version"]} (#{info["signed"]})", depth: 2
              when /^- Using previously-installed (?<module>[^ ]+) v(?<version>.+)$/
                info = $LAST_MATCH_INFO.named_captures
                log "- [USING] #{info["module"]} v#{info["version"]}", depth: 2
              when /^- Downloading plugin for provider "(?<provider>[^"]+)" \((?<provider_path>[^)]+)\) (?<version>.+)\.\.\.$/
                info = $LAST_MATCH_INFO.named_captures
                log "- #{info["provider"]} #{info["version"]}", depth: 2
              when "- Checking for available provider plugins..."
                # noop
              else
                p [state, line]
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
              p [state, line]
            else
              p [state, line]
            end
          end
        }

        [status.status, meta]
      end

      def process_validation(info)
        remedies = Set.new

        if info["error_count"] > 0 || info["warning_count"] > 0
          log "Encountered #{Paint[info["error_count"], :red]} Errors and #{Paint[info["warning_count"], :yellow]} Warnings!", depth: 2
          info["diagnostics"].each do |dinfo|
            color = dinfo["severity"] == "error" ? :red : :yellow
            log "#{Paint[dinfo["severity"].capitalize, color]}: #{dinfo["summary"]}", depth: 3
            if dinfo["detail"]&.include?("terraform init")
              remedies << :init
            elsif /there is no package for .+ cached in/.match?(dinfo["summary"])
              remedies << :init
            else
              log dinfo["detail"], depth: 4 if dinfo["detail"]
              if dinfo["range"]
                log format_validation_range(dinfo["range"], color), depth: 4
              end

              remedies << :unknown if dinfo["severity"] == "error"
            end
          end
        end

        remedies
      end

      private

      def format_validation_range(range, color)
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
        lines_info = lines.size == 1 ? "#{lines.first}:#{columns.first}" : "#{lines.first}:#{columns.first} to #{lines.last}:#{columns.last}"
        output << "on: #{range["filename"]} line#{lines.size > 1 ? "s" : ""}: #{lines_info}"

        if File.exist?(range["filename"])
          file_lines = File.read(range["filename"]).split("\n")
          extract_range = ([lines.first - context_lines, 0].max)..([lines.last + context_lines, file_lines.length - 1].min)
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
                output << "#{Paint[">", color]} #{index + 1}: #{painted_line}"
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
        suffix = line[end_col..-1]
        middle = line[start_col - 1..end_col - 1]
        "#{prefix}#{Paint[middle, *paint_options]}#{suffix}"
      end
    end
  end
end
