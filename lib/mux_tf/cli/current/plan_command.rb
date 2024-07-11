# frozen_string_literal: true

module MuxTf
  module Cli
    module Current
      class PlanCommand
        include TerraformHelpers
        include PiotrbCliUtils::CriCommandSupport
        extend PiotrbCliUtils::Util

        def plan_cmd
          define_cmd("plan", summary: "Re-run plan") do |_opts, _args, _cmd|
            run_validate && run_plan
          end
        end

        # returns boolean true if succeeded
        def run_validate(level: 1)
          Current.remedy_retry_helper(from: :validate, level: level) do
            validation_info = validate
            PlanFormatter.print_validation_errors(validation_info)
            remedies = PlanFormatter.process_validation(validation_info)
            [remedies, validation_info]
          end
        end

        def run_plan(targets: [], level: 1, retry_count: 0)
          plan_status, = Current.remedy_retry_helper(from: :plan, level: level, attempt: retry_count) {
            @last_lock_info = nil

            plan_filename = PlanFilenameGenerator.for_path

            plan_status, meta = create_plan(plan_filename, targets: targets)

            Current.print_errors_and_warnings(meta)

            remedies = detect_remedies_from_plan(meta)

            if remedies.include?(:unlock)
              @last_lock_info = extract_lock_info(meta)
              throw :abort, [plan_status, meta]
            end

            throw :abort, [plan_status, meta] if remedies.include?(:auth)

            [remedies, plan_status, meta]
          }

          case plan_status
          when :ok
            log "no changes", depth: 1
          when :error
            log "something went wrong", depth: 1
          when :changes
            unless ENV["JSON_PLAN"]
              log "Printing Plan Summary ...", depth: 1
              plan_filename = PlanFilenameGenerator.for_path
              pretty_plan_summary(plan_filename)
            end
            puts plan_summary_text if ENV["JSON_PLAN"]
          when :unknown
            # nothing
          end

          plan_status
        end

        private

        def validate
          log "Validating module ...", depth: 1
          tf_validate # from Terraform Helpers
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
            log pastel.yellow("terraform plan exited with an unknown exit code: #{exit_code}")
            [:unknown, meta]
          end
        end

        def detect_remedies_from_plan(meta)
          remedies = Set.new
          meta[:errors]&.each do |error|
            remedies << :plan if error[:message].include?("timeout while waiting for plugin to start")
          end
          remedies << :unlock if lock_error?(meta)
          remedies << :auth if meta[:need_auth]
          remedies
        end

        def lock_error?(meta)
          meta && meta["error"] == "lock"
        end

        def extract_lock_info(meta)
          {
            lock_id: meta["ID"],
            operation: meta["Operation"],
            who: meta["Who"],
            created: meta["Created"]
          }
        end

        def pretty_plan_summary(filename)
          plan = PlanSummaryHandler.from_file(filename)
          plan.simple_summary do |line|
            log line, depth: 2
          end
        end
      end
    end
  end
end
