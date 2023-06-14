# frozen_string_literal: true

module MuxTf
  class OnceHelper
    # once = OnceHelper.new
    # once.for(:phase).once { ... }.otherwise { ... }

    class StateEvaluator
      def initialize(once_helper, new_state)
        if once_helper.state == new_state
          @path = :otherwise
        else
          once_helper.state = new_state
          @path = :once
        end
      end

      def once
        yield if @path == :then
        self
      end

      def otherwise
        yield if @path == :otherwise
        self
      end
    end

    def initialize
      @state = nil
    end

    attr_accessor :state

    def for(new_state)
      StateEvaluator.new(self, new_state)
    end
  end
end
