module MuxTf
  module FormatterCommon
    def tf_cmd_json(cmd_call_proc, &block)
      last_stderr_line = nil
      handler = proc { |(stream, raw_line)|
        case stream
        when :command
          log "Running command: #{raw_line.strip} ...", depth: 2
        when :stdout
          parsed_line = JSON.parse(raw_line)
          parsed_line.keys.each do |key|
            if key[0] == "@"
              parsed_line[key[1..]] = parsed_line[key]
              parsed_line.delete(key)
            end
          end
          parsed_line.symbolize_keys!
          parsed_line[:stream] = stream
          if last_stderr_line
            emit_line_helper(last_stderr_line, &block)
            last_stderr_line = nil
          end
          emit_line_helper(parsed_line, &block)
        when :stderr
          parsed_line = parse_non_json_plan_line(raw_line)
          parsed_line[:stream] = stream

          if parsed_line[:blank]
            if last_stderr_line
              emit_line_helper(last_stderr_line, &block)
              last_stderr_line = nil
            end
          elsif parsed_line[:merge_up]
            if last_stderr_line
              last_stderr_line[:message] += "\n#{parsed_line[:message]}"
            else
              # this is just a standalone message then
              parsed_line.delete(:merge_up)
              last_stderr_line = parsed_line
            end
          elsif last_stderr_line
            emit_line_helper(last_stderr_line, &block)
            last_stderr_line = parsed_line
          else
            last_stderr_line = parsed_line
          end
        end
      }

      status = cmd_call_proc.call(handler)

      emit_line_helper(last_stderr_line, &block) if last_stderr_line
      status
    end

    def emit_line_helper(result, &block)
      result[:level] ||= result[:stream] == :stderr ? "error" : "info"
      result[:module] ||= result[:stream]
      result[:type] ||= "unknown"

      result[:message].lstrip! if result[:message] =~ /^\n/

      if result[:message].match(/^Terraform invocation failed in (.+)/)
        result[:type] = "tf_failed"

        lines = result[:message].split("\n")
        result[:diagnostic] = {
          "summary" => "Terraform invocation failed",
          "detail" => result[:message],
          roots: [],
          extra: []
        }

        lines.each do |line|
          if line.match(/^\s+\* \[(.+)\] exit status (\d+)$/)
            result[:diagnostic][:roots] << {
              path: $LAST_MATCH_INFO[1],
              status: $LAST_MATCH_INFO[2].to_i
            }
          elsif line.match(/^\d+ errors? occurred$/)
            # noop
          else
            result[:diagnostic][:extra] << line
          end
        end

        result[:message] = "Terraform invocation failed"
      end

      block.call(result)
    end

    def print_unhandled_error_line(parsed_line)
      if parsed_line[:diagnostic]
        color = :red
        dinfo = parsed_line[:diagnostic]
        log "#{pastel.decorate(dinfo['severity'].capitalize, color)}: #{dinfo['summary']}", depth: 3
        log dinfo["detail"].split("\n"), depth: 4 if dinfo["detail"]
        log format_validation_range(dinfo, color), depth: 4 if dinfo["range"]
      elsif parsed_line[:message] =~ /^\[reset\]/
        log pastel.red(parsed_line[:message].gsub(/^\[reset\]/, "")), depth: 3
      else
        p parsed_line
      end
    end

    def format_validation_range(dinfo, color)
      range = dinfo["range"]
      # filename: "../../../modules/pods/jane_pod/main.tf"
      # start:
      #   line: 151
      #   column: 27
      #   byte: 6632
      # end:
      #   line: 151
      #   column: 53
      #   byte: 6658

      context_lines = 3

      lines = range["start"]["line"]..range["end"]["line"]
      columns = range["start"]["column"]..range["end"]["column"]

      # on ../../../modules/pods/jane_pod/main.tf line 151, in module "jane":
      # 151:   jane_resources_preset = var.jane_resources_presetx
      output = []
      lines_info = if lines.size == 1
                     "#{lines.first}:#{columns.first}"
                   else
                     "#{lines.first}:#{columns.first} to #{lines.last}:#{columns.last}"
                   end
      output << "on: #{range['filename']} line#{lines.size > 1 ? 's' : ''}: #{lines_info}"

      # TODO: in terragrunt mode, we need to somehow figure out the path to the cache root, all the paths will end up being relative to that
      if File.exist?(range["filename"])
        file_lines = File.read(range["filename"]).split("\n")
        extract_range = (([lines.first - context_lines,
                           0].max)..([lines.last + context_lines, file_lines.length - 1].min))
        file_lines.each_with_index do |line, index|
          if extract_range.cover?(index + 1)
            if lines.cover?(index + 1)
              start_col = 1
              end_col = :max
              if index + 1 == lines.first
                start_col = columns.first
              elsif index + 1 == lines.last
                start_col = columns.last
              end
              painted_line = paint_line(line, color, start_col: start_col, end_col: end_col)
              output << "#{pastel.decorate('>', color)} #{index + 1}: #{painted_line}"
            else
              output << "  #{index + 1}: #{line}"
            end
          end
        end
      elsif dinfo["snippet"]
        # {
        #   "context"=>"locals",
        #   "code"=>"        aws_iam_policy.crossplane_aws_ecr.arn",
        #   "start_line"=>72,
        #   "highlight_start_offset"=>8,
        #   "highlight_end_offset"=>41,
        #   "values"=>[]
        # }
        output << "Code:"
        dinfo["snippet"]["code"].split("\n").each do |l|
          output << " > #{l}"
        end
      end

      output
    end

    def paint_line(line, *paint_options, start_col: 1, end_col: :max)
      end_col = line.length if end_col == :max
      prefix = line[0, start_col - 1]
      suffix = line[end_col..]
      middle = line[start_col - 1..end_col - 1]
      "#{prefix}#{pastel.decorate(middle, *paint_options)}#{suffix}"
    end
  end
end
