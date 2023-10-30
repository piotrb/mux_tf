# frozen_string_literal: true

module MuxTf
  module Coloring
    def pastel
      self.class.pastel
    end

    def self.included(other)
      other.extend(ClassMethods)
    end

    module ClassMethods
      def pastel
        instance = Pastel.new
        instance.alias_color(:orange, :yellow)
        instance.alias_color(:gray, :bright_black)
        instance.alias_color(:grey, :bright_black)
        instance
      end
    end
  end
end
