# frozen_string_literal: true

module MuxTf
  module ErrorHandlingMethods
    def setup_error_handling(parser, from_states:)
      parser.state(:init_error, /^Terraform encountered problems during initialisation/, [:none])
      parser.state(:error_block, /^╷/, from_states | [:after_error, :init_error])
      parser.state(:error_block_error, /^│ Error: /, [:error_block, :init_error])
      parser.state(:error_block_warning, /^│ Warning: /, [:error_block, :init_error])
      parser.state(:after_error, /^╵/, [:error_block, :error_block_error, :error_block_warning, :init_error])
    end

    def handle_error_states(meta, state, line)
      case state
      when :error_block
        if meta[:init_error]
          # turn this into an error first
          meta[:errors] ||= []
          meta[:errors] << {
            type: :error,
            message: meta[:init_error].join("\n")
            # body: meta[:init_error]
          }
          meta.delete(:init_error)
        end
        meta[:current_error] = {
          type: :unknown,
          body: []
        }
      when :error_block_error, :error_block_warning
        clean_line = pastel.strip(line).gsub(/^│ /, "")
        if clean_line =~ /^(Warning|Error): (.+)$/
          meta[:current_error][:type] = $LAST_MATCH_INFO[1].downcase.to_sym
          meta[:current_error][:message] = $LAST_MATCH_INFO[2]
        elsif clean_line == ""
          # skip double empty lines
          meta[:current_error][:body] << clean_line if meta[:current_error][:body].last != ""
        else
          meta[:current_error][:body] ||= []
          meta[:current_error][:body] << clean_line
        end
      when :after_error
        case pastel.strip(line)
        when "╵" # closing of an error block
          if meta[:current_error][:type] == :error
            meta[:errors] ||= []
            meta[:errors] << meta[:current_error]
          end
          if meta[:current_error][:type] == :warning
            meta[:warnings] ||= []
            meta[:warnings] << meta[:current_error]
          end
          meta.delete(:current_error)
        end
      when :init_error
        meta[:init_error] ||= []
        meta[:init_error] << line
      else
        return false
      end
      true
    end

    def log_unhandled_line(state, line, reason: nil)
      p [state, pastel.strip(line), reason]
    end

    def print_errors(meta)
      meta[:errors]&.each do |error|
        log "-" * 20
        log pastel.red("Error: #{error[:message]}")
        error[:body]&.each do |line|
          log pastel.red(line), depth: 1
        end
        log ""
      end
    end
  end
end
