# frozen_string_literal: true

module MuxTf
  class PlanFormatter
    extend TerraformHelpers
    extend PiotrbCliUtils::Util
    include Coloring

    extend ErrorHandlingMethods
    extend FormatterCommon

    class << self
      def pretty_plan(filename, targets: [])
        if ENV["JSON_PLAN"]
          pretty_plan_v2(filename, targets: targets)
        else
          pretty_plan_v1(filename, targets: targets)
        end
      end

      def parse_non_json_plan_line(raw_line)
        result = {}

        if raw_line.match(/^time=(?<timestamp>[^ ]+) level=(?<level>[^ ]+) msg=(?<message>.+?)(?: prefix=\[(?<prefix>.+?)\])?\s*$/)
          result.merge!($LAST_MATCH_INFO.named_captures.symbolize_keys)
          result[:module] = "terragrunt"
          result.delete(:prefix) unless result[:prefix]
          result[:prefix] = Pathname.new(result[:prefix]).relative_path_from(Dir.getwd).to_s if result[:prefix]

          result[:merge_up] = true if result[:message].match(/^\d+ errors? occurred:$/)
        elsif raw_line.strip == ""
          result[:blank] = true
        else
          result[:message] = raw_line
          result[:merge_up] = true
        end

        # time=2023-08-25T11:44:41-07:00 level=error msg=Terraform invocation failed in /Users/piotr/Work/janepods/.terragrunt-cache/BM86IAj5tW4bZga2lXeYT8tdOKI/V0IEypKSfyl-kHfCnRNAqyX02V8/modules/event-bus prefix=[/Users/piotr/Work/janepods/accounts/eks-dev/admin/apps/kube-system-event-bus]
        # time=2023-08-25T11:44:41-07:00 level=error msg=1 error occurred:
        #         * [/Users/piotr/Work/janepods/.terragrunt-cache/BM86IAj5tW4bZga2lXeYT8tdOKI/V0IEypKSfyl-kHfCnRNAqyX02V8/modules/event-bus] exit status 2
        #
        #
        result
      end

      def tf_plan_json(out:, targets: [], &block)
        tf_cmd_json(proc { |handler|
          tf_plan(out: out, detailed_exitcode: true, color: true, compact_warnings: false, json: true, input: false,
                  targets: targets, &handler)
        }, &block)
      end

      def parse_lock_info(detail)
        # Lock Info:
        #   ID:        4cc9c775-f0b7-3da7-25a4-94131afcef4d
        #   Path:      jane-terraform-eks-dev/admin/apps/kube-system-event-bus/terraform.tfstate
        #   Operation: OperationTypePlan
        #   Who:       piotr@Piotrs-Jane-MacBook-Pro.local
        #   Version:   1.5.4
        #   Created:   2023-08-25 19:03:38.821597 +0000 UTC
        #   Info:
        result = {}
        keys = %w[ID Path Operation Who Version Created]
        keys.each do |key|
          result[key] = detail.match(/^\s*#{key}:\s+(.+)$/)&.captures&.first
        end
        result
      end

      def print_plan_line(parsed_line, without: [], from: nil)
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

      def parse_tf_ui_line(parsed_line, meta, seen, skip_plan_summary: false)
        # p(parsed_line)
        case parsed_line[:type]
        when "version"
          meta[:terraform_version] = parsed_line[:terraform]
          meta[:terraform_ui_version] = parsed_line[:ui]
        when "apply_start", "refresh_start"
          first_in_group = !seen.call(parsed_line[:module], "apply_start") &&
                           !seen.call(parsed_line[:module], "refresh_start")
          log "Refreshing ", depth: 1, newline: false if first_in_group
          # {
          #   :hook=>{
          #     "resource"=>{
          #       "addr"=>"data.aws_eks_cluster_auth.this",
          #       "module"=>"",
          #       "resource"=>"data.aws_eks_cluster_auth.this",
          #       "implied_provider"=>"aws",
          #       "resource_type"=>"aws_eks_cluster_auth",
          #       "resource_name"=>"this",
          #       "resource_key"=>nil
          #     },
          #     "action"=>"read"
          #   }
          # }
          log ".", newline: false
        when "apply_complete", "refresh_complete"
          # {
          #   :hook=>{
          #     "resource"=>{
          #       "addr"=>"data.aws_eks_cluster_auth.this",
          #       "module"=>"",
          #       "resource"=>"data.aws_eks_cluster_auth.this",
          #       "implied_provider"=>"aws",
          #       "resource_type"=>"aws_eks_cluster_auth",
          #       "resource_name"=>"this",
          #       "resource_key"=>nil
          #     },
          #     "action"=>"read",
          #     "id_key"=>"id",
          #     "id_value"=>"admin",
          #     "elapsed_seconds"=>0
          #   }
          # }
          # noop
        when "resource_drift"
          first_in_group = !seen.call(parsed_line[:module], "resource_drift") &&
                           !seen.call(parsed_line[:module], "planned_change")
          # {
          #   :change=>{
          #     "resource"=>{"addr"=>"module.application.kubectl_manifest.application", "module"=>"module.application", "resource"=>"kubectl_manifest.application", "implied_provider"=>"kubectl", "resource_type"=>"kubectl_manifest", "resource_name"=>"application", "resource_key"=>nil},
          #     "action"=>"update"
          #   }
          # }
          if first_in_group
            log ""
            log ""
            log "Planned Changes:"
          end
          # {
          #   :change=>{
          #     "resource"=>{"addr"=>"aws_iam_policy.crossplane_aws_ecr[0]", "module"=>"", "resource"=>"aws_iam_policy.crossplane_aws_ecr[0]", "implied_provider"=>"aws", "resource_type"=>"aws_iam_policy", "resource_name"=>"crossplane_aws_ecr", "resource_key"=>0},
          #     "action"=>"update"
          #   },
          #   :type=>"resource_drift",
          #   :level=>"info",
          #   :message=>"aws_iam_policy.crossplane_aws_ecr[0]: Drift detected (update)",
          #   :module=>"terraform.ui",
          #   :timestamp=>"2023-09-26T17:11:46.340117-07:00",
          #   :stream=>:stdout
          # }

          log format("[%<action>s] %<addr>s - Drift Detected (%<change_action>s)",
                     action: PlanSummaryHandler.format_action(parsed_line[:change]["action"]),
                     addr: PlanSummaryHandler.format_address(parsed_line[:change]["resource"]["addr"]),
                     change_action: parsed_line[:change]["action"]), depth: 1
        when "planned_change"
          if skip_plan_summary
            log "" if first_in_group
          else
            first_in_group = !seen.call(parsed_line[:module], "resource_drift") &&
                             !seen.call(parsed_line[:module], "planned_change")
            # {
            #  :change=>
            #   {"resource"=>
            #     {"addr"=>"module.application.kubectl_manifest.application",
            #      "module"=>"module.application",
            #      "resource"=>"kubectl_manifest.application",
            #      "implied_provider"=>"kubectl",
            #      "resource_type"=>"kubectl_manifest",
            #      "resource_name"=>"application",
            #      "resource_key"=>nil},
            #    "action"=>"create"},
            #  :type=>"planned_change",
            #  :level=>"info",
            #  :message=>"module.application.kubectl_manifest.application: Plan to create",
            #  :module=>"terraform.ui",
            #  :timestamp=>"2023-08-25T14:48:46.005185-07:00",
            # }
            if first_in_group
              log ""
              log ""
              log "Planned Changes:"
            end
            log format("[%<action>s] %<addr>s",
                       action: PlanSummaryHandler.format_action(parsed_line[:change]["action"]),
                       addr: PlanSummaryHandler.format_address(parsed_line[:change]["resource"]["addr"])), depth: 1
          end
        when "change_summary"
          if skip_plan_summary
            log ""
          else
            # {
            #   :changes=>{"add"=>1, "change"=>0, "import"=>0, "remove"=>0, "operation"=>"plan"},
            #   :type=>"change_summary",
            #   :level=>"info",
            #   :message=>"Plan: 1 to add, 0 to change, 0 to destroy.",
            #   :module=>"terraform.ui",
            #   :timestamp=>"2023-08-25T14:48:46.005211-07:00",
            #   :stream=>:stdout
            # }
            log ""
            # puts parsed_line[:message]
            log "#{parsed_line[:changes]['operation'].capitalize} summary: " + parsed_line[:changes].without("operation").map { |k, v|
              color = PlanSummaryHandler.color_for_action(k)
              "#{pastel.yellow(v)} to #{pastel.decorate(k, color)}" if v.positive?
            }.compact.join(" ")
          end

        when "output"
          false
        else
          print_plan_line(parsed_line, from: "parse_tf_ui_line,else")
        end
      end

      def pretty_plan_v2(filename, targets: [])
        meta = {}
        meta[:seen] = {
          module_and_type: Set.new
        }

        status = tf_plan_json(out: filename, targets: targets) { |(parsed_line)|
          seen = proc { |module_arg, type_arg| meta[:seen][:module_and_type].include?([module_arg, type_arg]) }
          # first_in_state = !seen.call(parsed_line[:module], parsed_line[:type])

          case parsed_line[:level]
          when "info"
            case parsed_line[:module]
            when "terraform.ui"
              parse_tf_ui_line(parsed_line, meta, seen, skip_plan_summary: true)
            when "tofu.ui" # rubocop:disable Lint/DuplicateBranch
              parse_tf_ui_line(parsed_line, meta, seen, skip_plan_summary: true)
            else
              print_plan_line(parsed_line, from: "pretty_plan_v2,info,else")
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
                  print_plan_line(parsed_line, without: [:diagnostic], from: "pretty_plan_v2,error,handled")
                else
                  # print_plan_line(parsed_line, from: "pretty_plan_v2,error,unhandled_error")
                  print_unhandled_error_line(parsed_line)
                  current_meta_error[:printed] = true
                end
              end
            else
              print_plan_line(parsed_line, from: "pretty_plan_v2,error,else")
            end
          end

          meta[:seen][:module_and_type] << [parsed_line[:module], parsed_line[:type]]
        }
        [status.status, meta]
      end

      def setup_plan_v1_parser(parser)
        parser.state(:info, /^Acquiring state lock/)
        parser.state(:error, /(Error locking state|Error:)/, [:none, :blank, :info, :reading])
        parser.state(:reading, /: (Reading...|Read complete after)/, [:none, :info, :reading])
        parser.state(:none, /^$/, [:reading])
        parser.state(:refreshing, /^.+: Refreshing state... \[id=/, [:none, :info, :reading, :import])
        parser.state(:refreshing, /Refreshing Terraform state in-memory prior to plan.../,
                     [:none, :blank, :info, :reading])
        parser.state(:none, /^----------+$/, [:refreshing])
        parser.state(:none, /^$/, [:refreshing])

        parser.state(:import, /".+: Preparing import... \[id=.+\]$/, [:none, :import])
        parser.state(:none, /^$/, [:import])

        parser.state(:output_info, /^Changes to Outputs:$/, [:none])
        parser.state(:none, /^$/, [:output_info])

        parser.state(:plan_info, /Terraform will perform the following actions:/, [:none])
        parser.state(:plan_info, /You can apply this plan to save these new output values to the Terraform/, [:none])
        parser.state(:plan_summary, /^Plan:/, [:plan_info])

        parser.state(:plan_legend, /^Terraform used the selected providers to generate the following execution$/)
        parser.state(:none, /^$/, [:plan_legend])

        parser.state(:plan_info, /Terraform planned the following actions, but then encountered a problem:/, [:none])
        parser.state(:plan_info, /No changes. Your infrastructure matches the configuration./, [:none])

        parser.state(:plan_error, /Planning failed. Terraform encountered an error while generating this plan./, [:refreshing, :none])

        # this extends the error block to include the lock info
        parser.state(:error_lock_info, /Lock Info/, [:error_block_error])
        parser.state(:after_error, /^╵/, [:error_lock_info])
      end

      def handle_plan_v1_line(state, line, meta, first_in_state:, stripped_line:)
        case state
        when :none
          if line.blank?
          # nothing
          elsif stripped_line.match(/Error when retrieving token from sso/) || stripped_line.match(/Error loading SSO Token/)
            meta[:need_auth] = true
            log pastel.red("authentication problem"), depth: 2
          else
            log_unhandled_line(state, line, reason: "unexpected non blank line in :none state")
          end
        when :reading
          if stripped_line.match(/^(.+): Reading...$/)
            log "Reading: #{$LAST_MATCH_INFO[1]} ...", depth: 2
          elsif stripped_line.match(/^(.+): Read complete after ([^\[]+)(?: \[(.+)\])?$/)
            if $LAST_MATCH_INFO[3]
              log "Reading Complete: #{$LAST_MATCH_INFO[1]} after #{$LAST_MATCH_INFO[2]} [#{$LAST_MATCH_INFO[3]}]", depth: 3
            else
              log "Reading Complete: #{$LAST_MATCH_INFO[1]} after #{$LAST_MATCH_INFO[2]}", depth: 3
            end
          else
            log_unhandled_line(state, line, reason: "unexpected line in :reading state")
          end
        when :import
          # github_repository_topics.this[\"tf-k8s-infra-modules\"]: Preparing import... [id=tf-k8s-infra-modules]
          matches = stripped_line.match(/^(?<resource>.+): Preparing import... \[id=(?<id>.+)\]$/)
          if matches
            log "Importing #{pastel.cyan(matches[:resource])} (id=#{pastel.yellow(matches[:id])}) ...", depth: 2
          else
            p [:import, "couldn't parse line:", stripped_line]
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
          if stripped_line == ""
            meta[:current_error][:body] << stripped_line if meta[:current_error][:body].last != ""
          else
            meta[:current_error][:body] << stripped_line
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
          return false
        end
        true
      end

      def pretty_plan_v1(filename, targets: [])
        meta = {}
        init_phase = :none

        parser = StatefulParser.new(normalizer: pastel.method(:strip))

        InitFormatter.setup_init_parser(parser)
        setup_plan_v1_parser(parser)

        setup_error_handling(parser,
                             from_states: [:plan_error, :none, :blank, :info, :reading, :plan_summary, :refreshing] + [:plugins, :modules_init])

        last_state = nil

        stderr_handler = StderrLineHandler.new(operation: :plan)

        status = tf_plan(out: filename, detailed_exitcode: true, compact_warnings: true, targets: targets, split_streams: true) { |(stream, raw_line)|
          case stream
          when :command
            log "Running command: #{raw_line.strip} ...", depth: 2
          when :stderr
            stderr_handler.handle(raw_line)
          when :stdout
            stripped_line = pastel.strip(raw_line.rstrip)
            parser.parse(raw_line.rstrip) do |state, line|
              first_in_state = last_state != state

              if (handled = handle_plan_v1_line(state, line, meta, first_in_state: first_in_state, stripped_line: stripped_line))
                # great!
              elsif (handled = InitFormatter.handle_init_line(state, line, meta, phase: init_phase, stripped_line: stripped_line))
                init_phase = handled[:phase]
              elsif handle_error_states(meta, state, line)
                # no-op
              else
                log_unhandled_line(state, line, reason: "unexpected state")
              end

              last_state = state
            end
          end
        }

        stderr_handler.flush
        stderr_handler.merge_meta_into(meta)

        meta[:errors]&.each do |error|
          if error[:message] == "Error acquiring the state lock"
            meta["error"] = "lock"
            meta.merge!(parse_lock_info(error[:body].join("\n")))
          end
        end

        [status.status, meta]
      end

      def print_validation_errors(info)
        return unless info["error_count"].positive? || info["warning_count"].positive?

        log "Encountered #{pastel.red(info['error_count'])} Errors and #{pastel.yellow(info['warning_count'])} Warnings!", depth: 2
        info["diagnostics"].each do |dinfo|
          color = dinfo["severity"] == "error" ? :red : :yellow
          log "#{pastel.decorate(dinfo['severity'].capitalize, color)}: #{dinfo['summary']}", depth: 3
          log dinfo["detail"].split("\n"), depth: 4 if dinfo["detail"]
          log format_validation_range(dinfo, color), depth: 4 if dinfo["range"]
        end
      end

      def process_validation(info)
        remedies = Set.new

        if info["error_count"].positive? || info["warning_count"].positive?
          info["diagnostics"].each do |dinfo| # rubocop:disable Metrics/BlockLength
            item_handled = false

            case dinfo["summary"]
            when /there is no package for .+ cached in/,
                /Missing required provider/,
                /Module not installed/,
                /Module source has changed/,
                /Required plugins are not installed/,
                /Module version requirements have changed/,
                /to install all modules required by this configuration/
              remedies << :init
              item_handled = true
            when /Missing required argument/,
                /Error in function call/,
                /Invalid value for input variable/,
                /Unsupported block type/,
                /Reference to undeclared input variable/,
                /Invalid reference/,
                /Unsupported attribute/,
                /Invalid depends_on reference/
              remedies << :user_error
              item_handled = true
            end

            if dinfo["severity"] == "error" && dinfo["snippet"]
              # trying something new .. assuming anything with a snippet is a user error
              remedies << :user_error
              item_handled = true
            end

            case dinfo["detail"]
            when /timeout while waiting for plugin to start/
              remedies << :init
              item_handled = true
            end

            if dinfo["severity"] == "warning"
              remedies << :user_warning
              item_handled = true
            end

            next if item_handled

            puts "!! don't know how to handle this validation error"
            puts dinfo.inspect
            remedies << :unknown if dinfo["severity"] == "error"
          end
        end

        remedies
      end
    end
  end
end
