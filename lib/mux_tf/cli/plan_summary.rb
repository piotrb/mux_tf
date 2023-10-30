# frozen_string_literal: true

module MuxTf
  module Cli
    module PlanSummary
      extend PiotrbCliUtils::Util
      extend PiotrbCliUtils::ShellHelpers
      extend TerraformHelpers
      import Coloring

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

          raise "must specify plan file in interactive mode" if options[:interactive] && args[0].blank?

          plan = if args[0]
                   PlanSummaryHandler.from_file(args[0])
                 else
                   PlanSummaryHandler.from_data(JSON.parse($stdin.read))
                 end

          if options[:interactive]
            abort_message = catch(:abort) { plan.run_interactive }
            log pastel.red("Aborted: #{abort_message}") if abort_message
          else
            if options[:hierarchy]
              plan.nested_summary.each do |line|
                puts line
              end
            else
              plan.flat_summary.each do |line|
                puts line
              end
              plan.output_summary.each do |line|
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
