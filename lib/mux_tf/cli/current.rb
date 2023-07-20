# frozen_string_literal: true

require "bundler"

module MuxTf
  module Cli
    module Current # rubocop:disable Metrics/ModuleLength
      extend TerraformHelpers
      extend PiotrbCliUtils::Util
      extend PiotrbCliUtils::CriCommandSupport
      extend PiotrbCliUtils::CmdLoop

      class << self
        def run(args)
          version_check

          if args[0] == "cli"
            cmd_loop
            return
          end

          folder_name = File.basename(Dir.getwd)
          log "Processing #{Paint[folder_name, :cyan]} ..."

          ENV["TF_IN_AUTOMATION"] = "1"
          ENV["TF_INPUT"] = "0"

          return launch_cmd_loop(:error) unless run_validate

          if ENV["TF_UPGRADE"]
            upgrade_status, _upgrade_meta = run_upgrade
            return launch_cmd_loop(:error) unless upgrade_status == :ok
          end

          plan_status = run_plan

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

        def plan_filename
          PlanFilenameGenerator.for_path
        end

        private

        def version_check
          return unless VersionCheck.has_updates?

          log Paint["=" * 80, :yellow]
          log "New version of #{Paint['mux_tf', :cyan]} is available!"
          log "You are currently on version: #{Paint[VersionCheck.current_gem_version, :yellow]}"
          log "Latest version found is: #{Paint[VersionCheck.latest_gem_version, :green]}"
          log "Run `#{Paint['gem install mux_tf', :green]}` to update!"
          log Paint["=" * 80, :yellow]
        end

        def run_validate
          remedies = PlanFormatter.process_validation(validate)
          status, _results = process_remedies(remedies)
          status
        end

        def process_remedies(remedies, retry_count: 0) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
          results = {}
          if retry_count > 5
            log "giving up because retry_count: #{retry_count}", depth: 1
            log "unprocessed remedies: #{remedies.to_a}", depth: 1
            return [false, results]
          end
          if remedies.delete? :init
            log "[remedy] Running terraform init ...", depth: 2
            remedies = PlanFormatter.init_status_to_remedies(*PlanFormatter.run_tf_init)
            status, r_results = process_remedies(remedies)
            results.merge!(r_results)
            if status
              remedies = PlanFormatter.process_validation(validate)
              return [false, results] unless process_remedies(remedies)
            end
          end
          if remedies.delete?(:plan)
            log "[remedy] Running terraform plan ...", depth: 2
            plan_status = run_plan(retry_count: retry_count)
            results[:plan_status] = plan_status
            return [false, results] unless [:ok, :changes].include?(plan_status)
          end
          if remedies.delete? :reconfigure
            log "[remedy] Running terraform init ...", depth: 2
            remedies = PlanFormatter.init_status_to_remedies(*PlanFormatter.run_tf_init(reconfigure: true))
            status, r_results = process_remedies(remedies)
            results.merge!(r_results)
            return [false, results] unless status
          end
          unless remedies.empty?
            log "unprocessed remedies: #{remedies.to_a}", depth: 1
            return [false, results]
          end
          [true, results]
        end

        def validate
          log "Validating module ...", depth: 1
          tf_validate.parsed_output
        end

        def create_plan(filename, targets: [])
          log "Preparing Plan ...", depth: 1
          exit_code, meta = PlanFormatter.pretty_plan(filename, targets: targets)
          case exit_code
          when 0
            [:ok, meta]
          when 1
            [:error, meta]
          when 2
            [:changes, meta]
          else
            log Paint["terraform plan exited with an unknown exit code: #{exit_code}", :yellow]
            [:unknown, meta]
          end
        end

        def launch_cmd_loop(status)
          return if ENV["NO_CMD"]

          case status
          when :error, :unknown
            log Paint["Dropping to command line so you can fix the issue!", :red]
          when :changes
            log Paint["Dropping to command line so you can review the changes.", :yellow]
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
            prompt = "[#{Paint[status.to_s, :red]}] #{prompt}"
          when :changes
            prompt = "[#{Paint[status.to_s, :yellow]}] #{prompt}"
          end

          run_cmd_loop(prompt) do |cmd|
            throw(:stop, :no_input) if cmd == ""
            args = Shellwords.split(cmd)
            root_cmd.run(args, {}, hard_exit: false)
          end
        end

        def build_root_cmd
          root_cmd = define_cmd(nil)

          root_cmd.add_command(plan_cmd)
          root_cmd.add_command(apply_cmd)
          root_cmd.add_command(shell_cmd)
          root_cmd.add_command(force_unlock_cmd)
          root_cmd.add_command(upgrade_cmd)
          root_cmd.add_command(reconfigure_cmd)
          root_cmd.add_command(interactive_cmd)

          root_cmd.add_command(exit_cmd)
          root_cmd
        end

        def plan_cmd
          define_cmd("plan", summary: "Re-run plan") do |_opts, _args, _cmd|
            run_validate && run_plan
          end
        end

        def apply_cmd
          define_cmd("apply", summary: "Apply the current plan") do |_opts, _args, _cmd|
            status = tf_apply(filename: plan_filename)
            if status.success?
              plan_status = run_plan
              throw :stop, :done if plan_status == :ok
            else
              log "Apply Failed!"
            end
          end
        end

        def shell_cmd
          define_cmd("shell", summary: "Open your default terminal in the current folder") do |_opts, _args, _cmd|
            log Paint["Launching shell ...", :yellow]
            log Paint["When it exits you will be back at this prompt.", :yellow]
            system ENV.fetch("SHELL")
          end
        end

        def force_unlock_cmd
          define_cmd("force-unlock", summary: "Force unlock state after encountering a lock error!") do
            prompt = TTY::Prompt.new(interrupt: :noop)

            table = TTY::Table.new(header: %w[Field Value])
            table << ["Lock ID", @plan_meta["ID"]]
            table << ["Operation", @plan_meta["Operation"]]
            table << ["Who", @plan_meta["Who"]]
            table << ["Created", @plan_meta["Created"]]

            puts table.render(:unicode, padding: [0, 1])

            if @plan_meta && @plan_meta["error"] == "lock"
              done = catch(:abort) {
                if @plan_meta["Operation"] != "OperationTypePlan" && !prompt.yes?(
                  "Are you sure you want to force unlock a lock for operation: #{@plan_meta['Operation']}",
                  default: false
                )
                  throw :abort
                end

                throw :abort unless prompt.yes?(
                  "Are you sure you want to force unlock this lock?",
                  default: false
                )

                status = tf_force_unlock(id: @plan_meta["ID"])
                if status.success?
                  log "Done!"
                else
                  log Paint["Failed with status: #{status}", :red]
                end

                true
              }

              log Paint["Aborted", :yellow] unless done
            else
              log Paint["No lock error or no plan ran!", :red]
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
            status, meta = PlanFormatter.run_tf_init(reconfigure: true)
            if status != 0
              log meta.inspect unless meta.empty?
              log "Reconfigure Failed!"
            end
          end
        end

        def interactive_cmd
          define_cmd("interactive", summary: "Apply interactively") do |_opts, _args, _cmd|
            plan = PlanSummaryHandler.from_file(plan_filename)
            begin
              abort_message = catch(:abort) { plan.run_interactive }
              if abort_message
                log Paint["Aborted: #{abort_message}", :red]
              else
                run_plan
              end
            rescue Exception => e # rubocop:disable Lint/RescueException
              log e.full_message
              log "Interactive Apply Failed!"
            end
          end
        end

        def print_errors_and_warnings # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
          message = []
          message << Paint["#{@plan_meta[:warnings].length} Warnings", :yellow] if @plan_meta[:warnings]
          message << Paint["#{@plan_meta[:errors].length} Errors", :red] if @plan_meta[:errors]
          if message.length.positive?
            log ""
            log "Encountered: #{message.join(' and ')}"
            log ""
          end

          @plan_meta[:warnings]&.each do |warning|
            log "-" * 20
            log Paint["Warning: #{warning[:message]}", :yellow]
            warning[:body]&.each do |line|
              log Paint[line, :yellow], depth: 1
            end
            log ""
          end

          @plan_meta[:errors]&.each do |error|
            log "-" * 20
            log Paint["Error: #{error[:message]}", :red]
            error[:body]&.each do |line|
              log Paint[line, :red], depth: 1
            end
            log ""
          end

          return unless message.length.positive?

          log ""
        end

        def detect_remedies_from_plan
          remedies = Set.new
          @plan_meta[:errors]&.each do |error|
            remedies << :plan if error[:message].include?("timeout while waiting for plugin to start")
          end
          remedies
        end

        def run_plan(targets: [], retry_count: 0)
          plan_status, @plan_meta = create_plan(plan_filename, targets: targets)

          case plan_status
          when :ok
            log "no changes", depth: 1
          when :error
            # log "something went wrong", depth: 1
            print_errors_and_warnings
            remedies = detect_remedies_from_plan
            status, results = process_remedies(remedies, retry_count: retry_count)
            plan_status = results[:plan_status] if status
          when :changes
            log "Printing Plan Summary ...", depth: 1
            pretty_plan_summary(plan_filename)
          when :unknown
            # nothing
          end

          print_errors_and_warnings

          plan_status
        end

        public :run_plan

        def run_upgrade
          exit_code, meta = PlanFormatter.run_tf_init(upgrade: true)
          case exit_code
          when 0
            [:ok, meta]
          when 1
            [:error, meta]
          else
            log Paint["terraform init upgrade exited with an unknown exit code: #{exit_code}", :yellow]
            [:unknown, meta]
          end
        end

        def pretty_plan_summary(filename)
          plan = PlanSummaryHandler.from_file(filename)
          plan.flat_summary.each do |line|
            log line, depth: 2
          end
          plan.output_summary.each do |line|
            log line, depth: 2
          end
          log "", depth: 2
          log plan.summary, depth: 2
        end
      end
    end
  end
end
