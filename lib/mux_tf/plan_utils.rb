# frozen_string_literal: true

module MuxTf
  class PlanUtils
    extend TerraformHelpers
    extend PiotrbCliUtils::Util
    include Coloring

    KNOWN_AFTER_APPLY = "(known after apply)"
    SENSITIVE = "(sensitive value)"

    class << self
      def warning(message, binding_arg: binding)
        stack = binding_arg.send(:caller)
        stack_match = stack[0].match(/^(?<path>.+):(?<ln>\d+):in [`'](?<method>.+)'$/)
        msg = []
        if stack_match
          stack_line = stack_match.named_captures
          stack_line["path"].gsub!(MuxTf::ROOT, pastel.gray("{mux_tf}"))
          msg << "#{pastel.orange('WARNING')}: #{message}"
          msg << "at #{pastel.cyan(stack_line['path'])}:#{pastel.white(stack_line['ln'])}:in `#{pastel.cyan(stack_line['method'])}'"
        else
          p [stack_match, stack[0]]
          msg << "#{pastel.orange('WARNING')}: #{message}"
        end
        puts msg.join(" - ")
      end

      def update_placeholders(dst, src, placeholder)
        return unless src

        case src
        when Array
          src.each_with_index do |v, index|
            case v
            when TrueClass
              dst[index] = placeholder
            when FalseClass
              # do nothing
            when Hash
              dst[index] ||= {}
              update_placeholders(dst[index], v, placeholder)
            else
              warning "Unknown array value (index: #{index}) for sensitive: #{v.inspect}"
            end
          end
        when Hash
          src.each do |key, value|
            case value
            when TrueClass
              dst[key] = placeholder
            when FalseClass
              # do nothing
            when Array
              dst[key] ||= []
              update_placeholders(dst[key], value, placeholder)
            when Hash
              dst[key] ||= {}
              update_placeholders(dst[key], value, placeholder)
            else
              warning "Unknown value (key: #{key}) for sensitive: #{value.inspect}"
            end
          end
        end
      end

      def tf_show_json_resource_diff(resource)
        before = resource["change"]["before"] || {}
        after = resource["change"]["after"] || {}

        update_placeholders(after, resource["change"]["after_unknown"], KNOWN_AFTER_APPLY)

        before = before.sort.to_h
        after = after.sort.to_h

        update_placeholders(before, resource["change"]["before_sensitive"], SENSITIVE)
        update_placeholders(after, resource["change"]["after_sensitive"], SENSITIVE)

        # hash_diff = HashDiff::Comparison.new(before, after)
        # similarity: 0.0, numeric_tolerance: 1, array_path: true,
        Hashdiff.diff(before, after, use_lcs: false)
      end

      def string_diff(value1, value2)
        value1 = value1.split("\n")
        value2 = value2.split("\n")

        output = []
        diffs = Diff::LCS.diff value1, value2
        diffs.each do |diff|
          hunk = Diff::LCS::Hunk.new(value1, value2, diff, 5, 0)
          diff_lines = hunk.diff(:unified).split("\n")
          # diff_lines.shift # remove the first line
          output += diff_lines.map { |line| " #{line}" }
        end
        output
      end

      def valid_json?(value)
        value.is_a?(String) && !!JSON.parse(value)
      rescue JSON::ParserError
        false
      end

      def valid_yaml?(value)
        if value.is_a?(String)
          parsed = YAML.safe_load(value)
          parsed.is_a?(Hash) || parsed.is_a?(Array)
        else
          false
        end
      rescue Psych::DisallowedClass => _e
        # ap e
        false
      rescue Psych::SyntaxError => _e # rubocop:disable Lint/DuplicateBranch
        # ap e
        false
      end

      def colorize_symbol(symbol)
        case symbol
        when "+"
          pastel.green(symbol)
        when "~"
          pastel.yellow(symbol)
        when "-"
          pastel.red(symbol)
        when "?"
          pastel.orange(symbol)
        when "±"
          pastel.bright_red(symbol)
        when ">"
          pastel.blue(symbol)
        when " "
          symbol
        else
          warning "Unknown symbol: #{symbol.inspect}"
          symbol
        end
      end

      def wrap(text, prefix: "(", suffix: ")", newline: false, color: nil, indent: 0)
        result = String.new
        result << (color ? pastel.decorate(prefix, color) : prefix)
        result << "\n" if newline
        result << text.split("\n").map { |line|
          "#{' ' * indent}#{line}"
        }.join("\n")
        result << "\n" if newline
        result << (color ? pastel.decorate(suffix, color) : suffix)
        result
      end

      def indent(text, indent: 2, first_line_indent: 0)
        text.split("\n").map.with_index { |line, index|
          if index.zero?
            "#{' ' * first_line_indent}#{line}"
          else
            "#{' ' * indent}#{line}"
          end
        }.join("\n")
      end

      def in_display_representation(value)
        if valid_json?(value)
          json_body = JSON.pretty_generate(JSON.parse(value))
          wrap(json_body, prefix: "json(", suffix: ")", color: :gray)
        elsif valid_yaml?(value)
          yaml_body = YAML.dump(YAML.safe_load(value))
          yaml_body.gsub!(/^---\n/, "")
          wrap(yaml_body, prefix: "yaml(", suffix: ")", newline: true, color: :gray, indent: 2)
        elsif [KNOWN_AFTER_APPLY, SENSITIVE].include?(value)
          pastel.gray(value)
        elsif value.is_a?(String) && value.include?("\n")
          wrap(value, prefix: "<<- EOT", suffix: "EOT", newline: true, color: :gray)
        # elsif value.is_a?(Array)
        #   body = value.ai.rstrip
        #   wrap(body, prefix: "", suffix: "", newline: false, color: :gray, indent: 2)
        elsif value.is_a?(Array)
          max_key = value.length.to_s.length
          body = "["
          value.each_with_index do |v, _index|
            # body += "\n  #{in_display_representation(index).ljust(max_key)}: "
            body += "\n"
            body += indent(in_display_representation(v), indent: 2, first_line_indent: 2)
            body += ","
          end
          body += "\n]"
          body
        elsif value.is_a?(Hash)
          max_key = value.keys.map(&:length).max
          body = "{"
          value.each do |k, v|
            body += "\n  #{in_display_representation(k).ljust(max_key)}: "
            body += indent(in_display_representation(v), indent: 2, first_line_indent: 0)
            body += ","
          end
          body += "\n}"
          body
        else
          value.inspect
        end
      end

      def format_value_diff(mode, value_arg)
        case mode
        when :both
          vleft = in_display_representation(value_arg[0])
          vright = in_display_representation(value_arg[1])
          if [vleft, vright].any? { |v| v.is_a?(String) && v.include?("\n") }
            if pastel.strip(vright) == KNOWN_AFTER_APPLY
              "#{vleft} -> #{vright}".split("\n")
            else
              string_diff(pastel.strip(vleft), pastel.strip(vright))
            end
          else
            "#{vleft} -> #{vright}".split("\n")
          end
        when :right
          vright = in_display_representation(value_arg[1])
          vright.split("\n")
        when :left, :first
          vleft = in_display_representation(value_arg[0])
          vleft.split("\n")
        end
      end

      def format_value(change)
        symbol, _key, *value_arg = change

        mode = :both
        case symbol
        when "+", "-"
          mode = :first
        when "~"
          mode = :both
        else
          warning "Unknown symbol: #{symbol.inspect}"
        end

        format_value_diff(mode, value_arg)
      end

      def get_pretty_action_and_symbol(actions)
        case actions
        when ["delete"]
          pretty_action = "delete"
          symbol = "-"
        when ["update"]
          pretty_action = "updated in-place"
          symbol = "~"
        when ["create"]
          pretty_action = "created"
          symbol = "+"
        when %w[delete create]
          pretty_action = "replaced (delete first)"
          symbol = "±"
        when ["read"]
          pretty_action = "read"
          symbol = ">"
        when ["no-op"]
          pretty_action = "no-op"
          symbol = " "
        else
          warning "Unknown action: #{actions.inspect}"
          pretty_action = actions.inspect
          symbol = "?"
        end

        [pretty_action, symbol]
      end

      # Example
      #   # kubectl_manifest.crossplane-provider-controller-config["aws-ecr"] will be updated in-place
      #   ~ resource "kubectl_manifest" "crossplane-provider-controller-config" {
      #         id                      = "/apis/pkg.crossplane.io/v1alpha1/controllerconfigs/aws-ecr-config"
      #         name                    = "aws-ecr-config"
      #       ~ yaml_body               = (sensitive value)
      #       ~ yaml_body_parsed        = <<-EOT
      #             apiVersion: pkg.crossplane.io/v1alpha1
      #             kind: ControllerConfig
      #             metadata:
      #               annotations:
      #           -     eks.amazonaws.com/role-arn: <AWS_PROVIDER_ARN> <<- irsa
      #           +     eks.amazonaws.com/role-arn: arn:aws:iam::852088082597:role/admin-crossplane-provider-aws-ecr
      #               name: aws-ecr-config
      #             spec:
      #               podSecurityContext:
      #                 fsGroup: 2000
      #         EOT
      #         # (12 unchanged attributes hidden)
      #     }
      def tf_show_json_resource(resource)
        pretty_action, symbol = get_pretty_action_and_symbol(resource["change"]["actions"])

        output = []

        global_indent = " " * 2

        output << ""
        output << "#{global_indent}#{pastel.bold("# #{resource['address']}")} will be #{pretty_action}"
        output << "#{global_indent}  >> #{action_reason_to_text(resource['action_reason'])}" if resource["action_reason"]
        output << "#{global_indent}#{colorize_symbol(symbol)} resource \"#{resource['type']}\" \"#{resource['name']}\" {"
        diff = tf_show_json_resource_diff(resource)
        max_diff_key_length = diff.map { |change| change[1].length }.max

        fields_which_caused_replacement = []

        if resource["change"]["replace_paths"]
          if resource["change"]["replace_paths"].length != 1
            warning "Multiple replace paths found for resource #{resource['address']}: #{resource['change']['replace_paths'].inspect}"
          elsif resource["change"]["replace_paths"][0].length != 1
            warning "Multiple fields found to be replaced for resource #{resource['address']}: #{resource['change']['replace_paths'].inspect}"
          else
            fields_which_caused_replacement << resource["change"]["replace_paths"][0][0]
          end
        end

        diff.each do |change|
          change_symbol, key, *_values = change
          prefix = format("#{global_indent}  #{colorize_symbol(change_symbol)} %s = ", key.ljust(max_diff_key_length))
          suffix = ""
          suffix = " (forces replacement)" if fields_which_caused_replacement.include?(key)
          blank_prefix = " " * pastel.strip(prefix).length
          format_value(change).each_with_index do |line, index|
            output << if index.zero?
                        "#{prefix}#{line}#{suffix}"
                      else
                        "#{blank_prefix}#{line}#{suffix}"
                      end
          end
        end
        output << "#{global_indent}}"

        output.join("\n")
      end

      def format_output_value_diff(mode, value_arg)
        case mode
        when :both
          vleft = in_display_representation(value_arg[0])
          vright = in_display_representation(value_arg[1])
          if [vleft, vright].any? { |v| v.is_a?(String) && v.include?("\n") }
            if pastel.strip(vright) == KNOWN_AFTER_APPLY
              "#{vleft} -> #{vright}".split("\n")
            else
              string_diff(pastel.strip(vleft), pastel.strip(vright))
            end
          else
            "#{vleft} -> #{vright}".split("\n")
          end
        when :right
          vright = in_display_representation(value_arg[1])
          vright.split("\n")
        when :left, :first
          vleft = in_display_representation(value_arg[0])
          vleft.split("\n")
        end
      end

      def get_x_type(key, change)
        return :hash if change[key].is_a?(Hash) || change["#{key}_sensitive"].is_a?(Hash) || change["#{key}_unknown"].is_a?(Hash)
        return :array if change[key].is_a?(Array) || change["#{key}_sensitive"].is_a?(Array) || change["#{key}_unknown"].is_a?(Array)

        :scalar
      end

      def get_value_type(change)
        case change["actions"]
        when ["create"]
          get_x_type("after", change)
        when ["delete"]
          get_x_type("before", change)
        when ["update"]
          bt = get_x_type("before", change)
          at = get_x_type("after", change)
          raise "Type mismatch before vs after: #{bt} != #{at}" if bt != at

          at
        when ["no-op"]
          :none
        else
          raise "Unknown action: #{change['actions'].inspect}"
        end
      end

      def prep_before_after(change)
        before = change["before"]
        after = change["after"]
        before = KNOWN_AFTER_APPLY if change["before_unknown"]
        before = SENSITIVE if change["before_sensitive"]
        after = KNOWN_AFTER_APPLY if change["after_unknown"]
        after = SENSITIVE if change["after_sensitive"]

        [before, after]
      end

      def tf_show_json_output(output_key, output_change, max_outer_key_length)
        _pretty_action, symbol = get_pretty_action_and_symbol(output_change["actions"])

        output = []

        global_indent = " " * 2

        value_type = get_value_type(output_change)

        start_prefix = format("#{global_indent}#{colorize_symbol(symbol)} %s = ", output_key.ljust(max_outer_key_length))
        blank_start_prefix = " " * pastel.strip(start_prefix).length
        outer_mode = :both
        outer_mode = :right if ["+"].include?(symbol)
        outer_mode = :left if ["-"].include?(symbol)
        outer_mode = :right if [" "].include?(symbol)

        case value_type
        when :hash
          output << "#{start_prefix}{"

          fake_resource = {
            "change" => output_change
          }
          diff = tf_show_json_resource_diff(fake_resource)
          max_diff_key_length = diff.map { |change| change[1].length }.max

          diff.each do |change|
            change_symbol, key, *_values = change
            prefix = format("#{global_indent}    #{colorize_symbol(change_symbol)} %s = ", key.ljust(max_diff_key_length))
            suffix = ""
            blank_prefix = " " * pastel.strip(prefix).length
            format_value(change).each_with_index do |line, index|
              output << if index.zero?
                          "#{prefix}#{line}#{suffix}"
                        else
                          "#{blank_prefix}#{line}#{suffix}"
                        end
            end
          end

          output << "#{global_indent}  }"
        when :array, :scalar, :none
          before, after = prep_before_after(output_change)
          format_value_diff(outer_mode, [before, after]).each_with_index do |line, index|
            output << if index.zero?
                        "#{start_prefix}#{line}"
                      else
                        "#{blank_start_prefix}#{line}"
                      end
          end
        else
          raise "Unknown value type: #{value_type.inspect}"
        end

        output.join("\n")
      end

      # See https://developer.hashicorp.com/terraform/internals/json-format
      def action_reason_to_text(action_reason)
        case action_reason
        when "replace_because_tainted"
          "because the object is tainted in the prior state"
        when "replace_because_cannot_update"
          "because the provider does not support updating the object, or the changed attributes"
        when "replace_by_request"
          "because the user requested the object to be replaced"
        when "delete_because_no_resource_config"
          "because the object is no longer in the configuration"
        when "delete_because_no_module"
          "because the module this object belongs to is no longer in the configuration"
        when "delete_because_wrong_repetition"
          "because of the repetition mode has changed"
        when "delete_because_count_index"
          "because the repetition count has changed"
        when "delete_because_each_key"
          "because the repetition key has changed"
        when "read_because_config_unknown"
          "because reading this will only be possible during apply"
        when "read_because_dependency_pending"
          "because reading this will only be possible after a dependency is available"
        else
          "because #{action_reason}"
        end
      end

      def text_version_of_plan_show_from_data(data)
        output = []

        output << "Terraform will perform the following actions:"

        if data["resource_drift"]
          output << ""
          output << "Resource Drift:"
          data["resource_drift"].each do |resource|
            output << tf_show_json_resource(resource)
          end
        end

        if data["resource_changes"]
          output << ""
          output << "Resource Changes:"
          data["resource_changes"].each do |resource|
            next if resource["change"]["actions"] == ["no-op"]

            output << tf_show_json_resource(resource)
          end
        end

        if data["output_changes"]
          output << ""
          output << "Changes to Outputs:"
          max_outer_key_length = data["output_changes"].keys.map(&:length).max || 0
          data["output_changes"].each do |key, output_change|
            output << tf_show_json_output(key, output_change, max_outer_key_length)
          end
        end

        output.join("\n")
      end
    end
  end
end
