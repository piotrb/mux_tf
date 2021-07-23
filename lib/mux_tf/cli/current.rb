# frozen_string_literal: true

require "bundler"

module MuxTf
  module Cli
    module Current
      extend TerraformHelpers
      extend PiotrbCliUtils::Util
      extend PiotrbCliUtils::CriCommandSupport
      extend PiotrbCliUtils::CmdLoop

      PLAN_FILENAME = "foo.tfplan"

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
            upgrade_status, upgrade_meta = run_upgrade
            return launch_cmd_loop(:error) unless upgrade_status == :ok
          end

          plan_status, @plan_meta = create_plan(PLAN_FILENAME)

          case plan_status
          when :ok
            log "no changes, exiting", depth: 1
          when :error
            log "something went wrong", depth: 1
            launch_cmd_loop(plan_status)
          when :changes
            log "Printing Plan Summary ...", depth: 1
            pretty_plan_summary(PLAN_FILENAME)
            launch_cmd_loop(plan_status)
          when :unknown
            launch_cmd_loop(plan_status)
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          puts Paint["Unhandled Exception!", :red]
          puts "=" * 20
          puts e.full_message
          puts
          puts "< press enter to continue >"
          gets
          exit 1
        end

        private

        def version_check
          if VersionCheck.has_updates?
            log Paint["=" * 80, :yellow]
            log "New version of #{Paint["mux_tf", :cyan]} is available!"
            log "You are currently on version: #{Paint[VersionCheck.current_gem_version, :yellow]}"
            log "Latest version found is: #{Paint[VersionCheck.latest_gem_version, :green]}"
            log "Run `#{Paint["gem install mux_tf", :green]}` to update!"
            log Paint["=" * 80, :yellow]
          end
        end

        def run_validate
          remedies = PlanFormatter.process_validation(validate)
          process_remedies(remedies)
        end

        def process_remedies(remedies)
          if remedies.delete? :init
            log "Running terraform init ...", depth: 2
            remedies = PlanFormatter.init_status_to_remedies(*PlanFormatter.run_tf_init)
            if process_remedies(remedies)
              remedies = PlanFormatter.process_validation(validate)
              return false unless process_remedies(remedies)
            end
          end
          if remedies.delete? :reconfigure
            log "Running terraform init ...", depth: 2
            remedies = PlanFormatter.init_status_to_remedies(*PlanFormatter.run_tf_init(reconfigure: true))
            return false unless process_remedies(remedies)
          end
          unless remedies.empty?
            log "unprocessed remedies: #{remedies.to_a}", depth: 1
            return false
          end
          true
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
            status = tf_apply(filename: PLAN_FILENAME)
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
            system ENV["SHELL"]
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
                if @plan_meta["Operation"] != "OperationTypePlan"
                  throw :abort unless prompt.yes?(
                    "Are you sure you want to force unlock a lock for operation: #{@plan_meta["Operation"]}",
                    default: false
                  )
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
            plan = PlanSummaryHandler.from_file(PLAN_FILENAME)
            begin
              abort_message = catch :abort do
                plan.run_interactive
              end
              if abort_message
                log Paint["Aborted: #{abort_message}", :red]
              else
                run_plan
              end
            rescue Exception => e
              log e.full_message
              log "Interactive Apply Failed!"
            end
          end
        end

        def run_plan(targets: [])
          plan_status, @plan_meta = create_plan(PLAN_FILENAME, targets: targets)

          case plan_status
          when :ok
            log "no changes", depth: 1
          when :error
            log "something went wrong", depth: 1
          when :changes
            log "Printing Plan Summary ...", depth: 1
            pretty_plan_summary(PLAN_FILENAME)
          when :unknown
            # nothing
          end
          plan_status
        end

        def run_upgrade
          exit_code, meta = PlanFormatter.run_tf_init(upgrade: true)
          case exit_code
          when 0
            [:ok, meta]
          when 1
            [:error, meta]
          # when 2
          #   [:changes, meta]
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
          log "", depth: 2
          log plan.summary, depth: 2
        end
      end
    end
  end
end
