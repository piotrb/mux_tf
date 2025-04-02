# frozen_string_literal: true

module MuxTf
  class PlanSummaryHandler
    extend TerraformHelpers
    include TerraformHelpers
    include PiotrbCliUtils::Util
    include Coloring

    class << self
      def from_file(file)
        data = data_from_file(file)
        new data
      end

      def data_from_file(file)
        if File.exist?("#{file}.json") && File.mtime("#{file}.json").to_f >= File.mtime(file).to_f
          JSON.parse(File.read("#{file}.json"))
        else
          puts "Analyzing changes ... #{file}"
          result = tf_show(file, json: true)
          data = result.parsed_output
          File.write("#{file}.json", JSON.dump(data))
          data
        end
      end

      def from_data(data)
        new(data)
      end

      def color_for_action(action)
        case action
        when "create", "add"
          :green
        when "update", "change", "import-update"
          :yellow
        when "delete", "remove"
          :red
        when "replace" # rubocop:disable Lint/DuplicateBranch
          :red
        when "replace (create before delete)" # rubocop:disable Lint/DuplicateBranch
          :red
        when "read"
          :cyan
        when "import" # rubocop:disable Lint/DuplicateBranch
          :cyan
        else
          :reset
        end
      end

      def symbol_for_action(action)
        case action
        when "create"
          "+"
        when "update"
          "~"
        when "delete"
          "-"
        when "replace"
          "∓"
        when "replace (create before delete)"
          "±"
        when "read"
          ">"
        when "import"
          "→"
        when "import-update"
          "↗︎"
        else
          action
        end
      end

      def format_action(action)
        color = color_for_action(action)
        symbol = symbol_for_action(action)
        pastel.decorate(symbol, color)
      end

      def format_address(address)
        result = []
        parts = ResourceTokenizer.tokenize(address)
        parts.each_with_index do |(part_type, part_value), index|
          case part_type
          when :rt
            result << "." if index.positive?
            result << pastel.cyan(part_value)
          when :rn
            result << "."
            result << part_value
          when :ri
            result << pastel.green(part_value)
          end
        end
        result.join
      end
    end

    def initialize(data)
      @parts = []

      data["output_changes"]&.each do |output_name, v|
        case v["actions"]
        when ["no-op"]
          # do nothing
        when ["create"]
          parts << {
            type: "output",
            action: "create",
            after_unknown: v["after_unknown"],
            sensitive: [v["before_sensitive"], v["after_sensitive"]],
            address: output_name
          }
        when ["update"]
          parts << {
            type: "output",
            action: "update",
            after_unknown: v["after_unknown"],
            sensitive: [v["before_sensitive"], v["after_sensitive"]],
            address: output_name
          }
        when ["delete"]
          parts << {
            type: "output",
            action: "delete",
            after_unknown: v["after_unknown"],
            sensitive: [v["before_sensitive"], v["after_sensitive"]],
            address: output_name
          }
        else
          puts "[??] #{output_name}"
          puts "UNKNOWN OUTPUT ACTIONS: #{v['actions'].inspect}"
          puts "TODO: update plan_summary to support this!"
        end
      end

      data["resource_changes"]&.each do |v|
        next unless v["change"]

        case v["change"]["actions"]
        when ["no-op"]
          # do nothing
          if v["change"]["importing"]
            parts << {
              type: "resource",
              action: "import",
              address: v["address"],
              deps: find_deps(data, v["address"])
            }
          end
        when ["create"]
          parts << {
            type: "resource",
            action: "create",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when ["update"]
          # ap [v["change"]["actions"], v["change"]["importing"]]
          parts << {
            type: "resource",
            action: v["change"]["importing"] ? "import-update" : "update",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when ["delete"]
          parts << {
            type: "resource",
            action: "delete",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when %w[delete create]
          parts << {
            type: "resource",
            action: "replace",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when %w[create delete]
          parts << {
            type: "resource",
            action: "replace (create before delete)",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when ["read"]
          parts << {
            type: "resource",
            action: "read",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        else
          puts "[??] #{v['address']}"
          puts "UNKNOWN RESOURCE ACTIONS: #{v['change']['actions'].inspect}"
          puts "TODO: update plan_summary to support this!"
        end
      end

      prune_unchanged_deps(parts)
    end

    def resource_parts
      parts.select { |part| part[:type] == "resource" }
    end

    def output_parts
      parts.select { |part| part[:type] == "output" }
    end

    def summary
      # resources
      resource_summary = {}
      resource_parts.each do |part|
        resource_summary[part[:action]] ||= 0
        resource_summary[part[:action]] += 1
      end
      resource_pieces = resource_summary.map { |k, v|
        color = self.class.color_for_action(k)
        "#{pastel.yellow(v)} to #{pastel.decorate(k, color)}"
      }

      # outputs
      output_summary = {}
      output_parts.each do |part|
        output_summary[part[:action]] ||= 0
        output_summary[part[:action]] += 1
      end
      output_pieces = output_summary.map { |k, v|
        color = self.class.color_for_action(k)
        "#{pastel.yellow(v)} to #{pastel.decorate(k, color)}"
      }

      if resource_pieces.any? || output_pieces.any?
        [
          "Plan Summary:",
          resource_pieces.any? ? resource_pieces.join(pastel.gray(", ")) : nil,
          output_pieces.any? ? "Outputs: #{output_pieces.join(pastel.gray(', '))}" : nil
        ].compact.join(" ")
      else
        "Plan Summary: no changes"
      end
    end

    def flat_summary
      resource_parts.map do |part|
        "[#{self.class.format_action(part[:action])}] #{self.class.format_address(part[:address])}"
      end
    end

    def sensitive_summary(before_value, after_value)
      # before vs after
      if before_value && after_value
        "(#{pastel.yellow('sensitive')})"
      elsif before_value
        "(#{pastel.red('-sensitive')})"
      elsif after_value
        "(#{pastel.cyan('+sensitive')})"
      end
    end

    def output_summary
      result = []
      output_parts.each do |part|
        pieces = [
          "[#{self.class.format_action(part[:action])}]",
          self.class.format_address("output.#{part[:address]}"),
          part[:after_unknown] ? "(unknown)" : nil,
          sensitive_summary(*part[:sensitive])
        ].compact
        result << pieces.join(" ")
      end
      result
    end

    def simple_summary(&printer)
      printer = method(:puts) if printer.nil?

      flat_summary.each do |line|
        printer.call line
      end
      output_summary.each do |line|
        printer.call line
      end
      printer.call ""
      printer.call summary
    end

    def nested_summary
      result = []
      parts = resource_parts.deep_dup
      until parts.empty?
        part = parts.shift
        if part[:deps] == []
          indent = if part[:met_deps] && !part[:met_deps].empty?
                     "  "
                   else
                     ""
                   end
          message = "[#{self.class.format_action(part[:action])}]#{indent} #{self.class.format_address(part[:address])}"
          message += " - (needs: #{part[:met_deps].join(', ')})" if part[:met_deps]
          result << message
          parts.each do |ipart|
            d = ipart[:deps].delete(part[:address])
            if d
              ipart[:met_deps] ||= []
              ipart[:met_deps] << d
            end
          end
        else
          parts.unshift part
        end
      end
      result
    end

    def run_interactive
      prompt = TTY::Prompt.new
      result = prompt.multi_select("Update resources:", per_page: 99, echo: false) { |menu|
        resource_parts.each do |part|
          label = "[#{self.class.format_action(part[:action])}] #{self.class.format_address(part[:address])}"
          menu.choice label, part[:address]
        end
      }

      if result.empty?
        throw :abort, "nothing selected"
      else
        result
      end
    end

    private

    attr_reader :parts

    def prune_unchanged_deps(_parts)
      valid_addresses = resource_parts.map { |part| part[:address] }

      resource_parts.each do |part|
        part[:deps].select! { |dep| valid_addresses.include?(dep) }
      end
    end

    def find_deps(data, address)
      result = []

      m = address.match(/\[(.+)\]$/)
      if m
        address = m.pre_match
        index = m[1][0] == '"' ? m[1].gsub(/^"(.+)"$/, '\1') : m[1].to_i
      end

      if data.dig("prior_state", "values", "root_module", "resources")
        resource = data["prior_state"]["values"]["root_module"]["resources"].find { |inner_resource|
          address == inner_resource["address"] && index == inner_resource["index"]
        }
      end

      result += resource["depends_on"] if resource && resource["depends_on"]

      resource, parent_address = find_config(data["configuration"], "root_module", address, [])
      if resource
        deps = []
        resource["expressions"]&.each_value do |v|
          deps << v["references"] if v.is_a?(Hash) && v["references"]
        end
        result += deps.map { |s| (parent_address + [s]).join(".") }
      end

      result
    end

    def find_config(module_root, module_name, address, parent_address)
      module_info = if parent_address.empty?
                      module_root[module_name]
                    elsif module_root && module_root[module_name]
                      module_root[module_name]["module"]
                    else
                      {}
                    end

      if (m = address.match(/^module\.([^.]+)\./))
        find_config(module_info["module_calls"], m[1], m.post_match, parent_address + ["module.#{m[1]}"])
      else
        if module_info["resources"]
          resource = module_info["resources"].find { |inner_resource|
            address == inner_resource["address"]
          }
        end
        [resource, parent_address]
      end
    end
  end
end
