module MuxTf
  class OnceHelper
    # once = OnceHelper.new
    # once.for(:phase).once { ... }.otherwise { ... }

    class StateEvaluator
      def initialize(once_helper, new_state)
        if once_helper.state != new_state
          once_helper.state = new_state
          @path = :once
        else
          @path = :otherwise
        end
      end

      def once(&block)
        if @path == :then
          yield
        end
      end

      def otherwise(&block)
        if @path == :otherwise
          yield
        end
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
