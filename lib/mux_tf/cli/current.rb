# frozen_string_literal: true

require "bundler"

module MuxTf
  module Cli
    module Current # rubocop:disable Metrics/ModuleLength
      extend TerraformHelpers
      extend PiotrbCliUtils::Util
      extend PiotrbCliUtils::CriCommandSupport
      extend PiotrbCliUtils::CmdLoop
      include Coloring

      class << self
        attr_accessor :plan_command

        def run(args)
          version_check

          self.plan_command = PlanCommand.new

          ENV["TF_IN_AUTOMATION"] = "1"
          ENV["TF_INPUT"] = "0"
          ENV["TERRAGRUNT_JSON_LOG"] = "1"
          ENV["TERRAGRUNT_FORWARD_TF_STDOUT"] = "1"

          if args[0] == "cli"
            cmd_loop
            return
          end

          unless args.empty?
            root_cmd = build_root_cmd
            valid_commands = root_cmd.subcommands.map(&:name)

            if args[0] && valid_commands.include?(args[0])
              stop_reason = catch(:stop) {
                root_cmd.run(args, {}, hard_exit: true)
              }
              log pastel.red("Stopped: #{stop_reason}") if stop_reason
              return
            end
          end

          folder_name = File.basename(Dir.getwd)
          log "Processing #{pastel.cyan(folder_name)} ..."

          return launch_cmd_loop(:error) unless @plan_command.run_validate

          if ENV["TF_UPGRADE"]
            upgrade_status, _upgrade_meta = run_upgrade
            return launch_cmd_loop(:error) unless upgrade_status == :ok
          end

          plan_status = @plan_command.run_plan

          case plan_status
          when :ok
            log "exiting", depth: 1
          when :error
            launch_cmd_loop(plan_status)
          when :changes # rubocop:disable Lint/DuplicateBranch
            launch_cmd_loop(plan_status)
          when :unknown # rubocop:disable Lint/DuplicateBranch
            launch_cmd_loop(plan_status)
          end
        end

        # block is expected to return a touple, the first element is a list of remedies
        # the rest are any additional results
        def remedy_retry_helper(from:, level: 1, attempt: 0, &block)
          catch(:abort) do
            until attempt > 1
              attempt += 1
              remedies, *results = block.call
              return results if remedies.empty?

              remedy_status, remedy_results = process_remedies(remedies, from: from, level: level)
              throw :abort, false if remedy_results[:user_error]
              return remedy_status if remedy_status
            end
            log "!! giving up because attempt: #{attempt}"
          end
        end

        def print_errors_and_warnings(meta)
          message = []
          message << pastel.yellow("#{meta[:warnings].length} Warnings") if meta[:warnings]
          message << pastel.red("#{meta[:errors].length} Errors") if meta[:errors]
          if message.length.positive?
            log ""
            log "Encountered: #{message.join(' and ')}"
            log ""
          end

          meta[:warnings]&.each do |warning|
            next if warning[:printed]
            log "-" * 20
            log pastel.yellow("Warning: #{warning[:message]}")
            warning[:body]&.each do |line|
              log pastel.yellow(line), depth: 1
            end
            log ""
          end

          meta[:errors]&.each do |error|
            next if error[:printed]
            log "-" * 20
            log pastel.red("Error: #{error[:message]}")
            error[:body]&.each do |line|
              log pastel.red(line), depth: 1
            end
            log ""
          end

          return unless message.length.positive?

          log ""
        end

        private

        def version_check
          return unless VersionCheck.has_updates?

          log pastel.yellow("=" * 80)
          log "New version of #{pastel.cyan('mux_tf')} is available!"
          log "You are currently on version: #{pastel.yellow(VersionCheck.current_gem_version)}"
          log "Latest version found is: #{pastel.green(VersionCheck.latest_gem_version)}"
          log "Run `#{pastel.green('gem install mux_tf')}` to update!"
          log pastel.yellow("=" * 80)
        end

        def process_remedies(remedies, from: nil, level: 1, retry_count: 0)
          remedies = remedies.dup
          remedy = nil
          wrap_log = lambda do |msg, color: nil|
            [
              from ? pastel.cyan("#{from} -> ") : nil,
              pastel.cyan(remedy ? "[remedy: #{remedy}]" : "[process remedies]"),
              " ",
              color ? pastel.decorate(msg, color) : msg,
              " ",
              level > 1 ? pastel.cyan("[lv #{level}]") : nil,
              retry_count.positive? ? pastel.cyan("[try #{retry_count}]") : nil
            ].compact.join
          end
          results = {}
          if retry_count > 5
            log wrap_log["giving up because retry_count: #{retry_count}", color: :yellow], depth: 1
            log wrap_log["unprocessed remedies: #{remedies.to_a}", color: :red], depth: 1
            return [false, results]
          end
          if remedies.delete? :init
            remedy = :init
            log wrap_log["Running terraform init ..."], depth: 2
            exit_code, meta = PlanFormatter.run_tf_init
            print_errors_and_warnings(meta)
            remedies = PlanFormatter.init_status_to_remedies(exit_code, meta)
            status, r_results = process_remedies(remedies, from: from, level: level + 1)
            results.merge!(r_results)
            return [true, r_results] if status
          end
          if remedies.delete?(:plan)
            remedy = :plan
            log wrap_log["Running terraform plan ..."], depth: 2
            plan_status = @plan_command.run_plan(retry_count: retry_count)
            results[:plan_status] = plan_status
            return [false, results] unless [:ok, :changes].include?(plan_status)
          end
          if remedies.delete? :reconfigure
            remedy = :reconfigure
            log wrap_log["Running terraform init ..."], depth: 2
            result = remedy_retry_helper(from: :reconfigure, level: level + 1, attempt: retry_count) {
              exit_code, meta = PlanFormatter.run_tf_init(reconfigure: true)
              print_errors_and_warnings(meta)
              remedies = PlanFormatter.init_status_to_remedies(exit_code, meta)
              [remedies, exit_code, meta]
            }
            unless result
              log wrap_log["Failed", color: :red], depth: 2
              return [false, result]
            end
          end
          if remedies.delete? :user_error
            remedy = :user_error
            log wrap_log["user error encountered!", color: :red]
            log wrap_log["-" * 40, color: :red]
            log wrap_log["!! User Error, Please fix the issue and try again", color: :red]
            log wrap_log["-" * 40, color: :red]
            results[:user_error] = true
            return [false, results]
          end
          if remedies.delete? :auth
            remedy = :auth
            log wrap_log["auth error encountered!", color: :red]
            log wrap_log["-" * 40, color: :red]
            log wrap_log["!! Auth Error, Please fix the issue and try again", color: :red]
            log wrap_log["-" * 40, color: :red]
            return [false, results]
          end

          # if there is warnings, but no other remedies .. then we assume all is ok
          return [true, results] if remedies.delete?(:user_warning) && remedies.empty?

          unless remedies.empty?
            remedy = nil
            log wrap_log["Unprocessed remedies: #{remedies.to_a}", color: :red], depth: 1 if level == 1
            return [false, results]
          end
          [true, results]
        end

        def launch_cmd_loop(status)
          return if ENV["NO_CMD"]

          case status
          when :error, :unknown
            log pastel.red("Dropping to command line so you can fix the issue!")
          when :changes
            log pastel.yellow("Dropping to command line so you can review the changes.")
          end
          cmd_loop(status)
        end

        def cmd_loop(status = nil)
          root_cmd = build_root_cmd

          folder_name = File.basename(Dir.getwd)

          puts root_cmd.help

          prompt = "#{folder_name} => "
          case status
          when :error, :unknown
            prompt = "[#{pastel.red(status.to_s)}] #{prompt}"
          when :changes
            prompt = "[#{pastel.yellow(status.to_s)}] #{prompt}"
          end

          run_cmd_loop(prompt) do |cmd|
            throw(:stop, :no_input) if cmd == ""
            args = Shellwords.split(cmd)
            root_cmd.run(args, {}, hard_exit: false)
          end
        end

        def build_root_cmd
          root_cmd = define_cmd(nil)

          root_cmd.add_command(@plan_command.plan_cmd)
          root_cmd.add_command(apply_cmd)
          root_cmd.add_command(shell_cmd)
          root_cmd.add_command(force_unlock_cmd)
          root_cmd.add_command(upgrade_cmd)
          root_cmd.add_command(reconfigure_cmd)
          root_cmd.add_command(interactive_cmd)
          root_cmd.add_command(plan_details_cmd)
          root_cmd.add_command(init_cmd)

          root_cmd.add_command(exit_cmd)
          root_cmd.add_command(define_cmd("help", summary: "Show help for commands") { |_opts, _args, cmd| puts cmd.supercommand.help })
          root_cmd
        end

        def plan_details_cmd
          define_cmd("details", summary: "Show Plan Details") do |_opts, _args, _cmd|
            puts @plan_command.plan_summary_text

            unless ENV["JSON_PLAN"]
              log "Printing Plan Summary ...", depth: 1

              plan_filename = PlanFilenameGenerator.for_path
              plan = PlanSummaryHandler.from_file(plan_filename)
              plan.simple_summary do |line|
                log line
              end
            end
            # puts plan_summary_text if ENV["JSON_PLAN"]
          end
        end

        def apply_cmd
          define_cmd("apply", summary: "Apply the current plan") do |_opts, _args, _cmd|
            plan_filename = PlanFilenameGenerator.for_path
            status = tf_apply(filename: plan_filename)
            if status.success?
              plan_status = @plan_command.run_plan
              throw :stop, :done if plan_status == :ok
            else
              log "Apply Failed!"
            end
          end
        end

        def shell_cmd
          define_cmd("shell", summary: "Open your default terminal in the current folder") do |_opts, _args, _cmd|
            log pastel.yellow("Launching shell ...")
            log pastel.yellow("When it exits you will be back at this prompt.")
            system ENV.fetch("SHELL")
          end
        end

        def force_unlock_cmd
          define_cmd("force-unlock", summary: "Force unlock state after encountering a lock error!") do # rubocop:disable Metrics/BlockLength
            prompt = TTY::Prompt.new(interrupt: :noop)

            lock_info = @plan_command.last_lock_info

            if lock_info
              table = TTY::Table.new(header: %w[Field Value])
              table << ["Lock ID", lock_info[:lock_id]]
              table << ["Operation", lock_info[:operation]]
              table << ["Who", lock_info[:who]]
              table << ["Created", lock_info[:created]]

              puts table.render(:unicode, padding: [0, 1])

              done = catch(:abort) {
                if lock_info[:operation] != "OperationTypePlan" && !prompt.yes?(
                  "Are you sure you want to force unlock a lock for operation: #{lock_info[:operation]}",
                  default: false
                )
                  throw :abort
                end

                throw :abort unless prompt.yes?(
                  "Are you sure you want to force unlock this lock?",
                  default: false
                )

                status = tf_force_unlock(id: lock_info[:lock_id])
                if status.success?
                  log "Done!"
                else
                  log pastel.red("Failed with status: #{status}")
                end

                true
              }

              log pastel.yellow("Aborted") unless done
            else
              log pastel.red("No lock error or no plan ran!")
            end
          end
        end

        def init_cmd
          define_cmd("init", summary: "Re-run init") do |_opts, _args, _cmd|
            exit_code, meta = PlanFormatter.run_tf_init
            print_errors_and_warnings(meta)
            if exit_code != 0
              log meta.inspect unless meta.empty?
              log "Init Failed!"
            end
          end
        end

        def upgrade_cmd
          define_cmd("upgrade", summary: "Upgrade modules/plguins") do |_opts, _args, _cmd|
            status, meta = run_upgrade
            if status != :ok
              log meta.inspect unless meta.empty?
              log "Upgrade Failed!"
            end
          end
        end

        def reconfigure_cmd
          define_cmd("reconfigure", summary: "Reconfigure modules/plguins") do |_opts, _args, _cmd|
            exit_code, meta = PlanFormatter.run_tf_init(reconfigure: true)
            print_errors_and_warnings(meta)
            if exit_code != 0
              log meta.inspect unless meta.empty?
              log "Reconfigure Failed!"
            end
          end
        end

        def interactive_cmd
          define_cmd("interactive", summary: "Apply interactively") do |_opts, _args, _cmd|
            plan_filename = PlanFilenameGenerator.for_path
            plan = PlanSummaryHandler.from_file(plan_filename)
            begin
              abort_message = catch(:abort) {
                result = plan.run_interactive
                log "Re-running apply with the selected resources ..."
                @plan_command.run_plan(targets: result)
              }
              if abort_message
                log pastel.red("Aborted: #{abort_message}")
              else
                @plan_command.run_plan
              end
            rescue Exception => e # rubocop:disable Lint/RescueException
              log e.full_message
              log "Interactive Apply Failed!"
            end
          end
        end

        def run_upgrade
          exit_code, meta = PlanFormatter.run_tf_init(upgrade: true)
          print_errors_and_warnings(meta)
          case exit_code
          when 0
            [:ok, meta]
          when 1
            [:error, meta]
          else
            log pastel.yellow("terraform init upgrade exited with an unknown exit code: #{exit_code}")
            [:unknown, meta]
          end
        end
      end
    end
  end
end
