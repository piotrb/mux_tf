# frozen_string_literal: true

module MuxTf
  module Cli
    module PlanSummary
      extend PiotrbCliUtils::Util
      extend PiotrbCliUtils::ShellHelpers
      extend TerraformHelpers

      class << self
        def run(args)
          options = {
            interactive: false,
            hierarchy: false
          }

          args = OptionParser.new { |opts|
            opts.on("-i") do |v|
              options[:interactive] = v
            end
            opts.on("-h") do |v|
              options[:hierarchy] = v
            end
          }.parse!(args)

          if options[:interactive]
            raise "must specify plan file in interactive mode" if args[0].blank?
          end

          plan = if args[0]
            PlanSummaryHandler.from_file(args[0])
          else
            PlanSummaryHandler.from_data(JSON.parse(STDIN.read))
          end

          if options[:interactive]
            abort_message = catch :abort do
              plan.run_interactive
            end
            if abort_message
              log Paint["Aborted: #{abort_message}", :red]
            end
          else
            if options[:hierarchy]
              plan.nested_summary.each do |line|
                puts line
              end
            else
              plan.flat_summary.each do |line|
                puts line
              end
            end
            puts
            puts plan.summary
          end
        end
      end
    end
  end
end
