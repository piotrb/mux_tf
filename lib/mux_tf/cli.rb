# frozen_string_literal: true

module MuxTf
  module Cli
    extend PiotrbCliUtils::Util

    def self.run(mode, args)
      case mode
      when :mux
        require_relative "cli/mux"
        MuxTf::Cli::Mux.run(args)
      when :current
        require_relative "cli/current"
        MuxTf::Cli::Current.run(args)
      when :plan_summary
        require_relative "cli/plan_summary"
        MuxTf::Cli::PlanSummary.run(args)
      else
        fail_with "unhandled mode: #{mode.inspect}"
      end
    end
  end
end
