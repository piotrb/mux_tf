# frozen_string_literal: true

module MuxTf
  class PlanSummaryHandler
    extend TerraformHelpers
    include TerraformHelpers
    include PiotrbCliUtils::Util

    def self.from_file(file)
      data = data_from_file(file)
      new data
    end

    def self.data_from_file(file)
      if File.exist?("#{file}.json") && File.mtime("#{file}.json").to_f >= File.mtime(file).to_f
        JSON.parse(File.read("#{file}.json"))
      else
        puts "Analyzing changes ..."
        result = tf_show(file, json: true)
        data = result.parsed_output
        File.write("#{file}.json", JSON.dump(data))
        data
      end
    end

    def self.from_data(data)
      new(data)
    end

    def initialize(data) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
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
        when ["create"]
          parts << {
            type: "resource",
            action: "create",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when ["update"]
          parts << {
            type: "resource",
            action: "update",
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

    def summary # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      # resources
      resource_summary = {}
      resource_parts.each do |part|
        resource_summary[part[:action]] ||= 0
        resource_summary[part[:action]] += 1
      end
      resource_pieces = resource_summary.map { |k, v|
        color = color_for_action(k)
        "#{Paint[v, :yellow]} to #{Paint[k, color]}"
      }

      # outputs
      output_summary = {}
      output_parts.each do |part|
        output_summary[part[:action]] ||= 0
        output_summary[part[:action]] += 1
      end
      output_pieces = output_summary.map { |k, v|
        color = color_for_action(k)
        "#{Paint[v, :yellow]} to #{Paint[k, color]}"
      }

      if resource_pieces.any? || output_pieces.any?
        [
          "Plan Summary:",
          resource_pieces.any? ? resource_pieces.join(Paint[", ", :gray]) : nil,
          output_pieces.any? ? "Outputs: #{output_pieces.join(Paint[', ', :gray])}" : nil
        ].compact.join(" ")
      else
        "Plan Summary: no changes"
      end
    end

    def flat_summary
      result = []
      resource_parts.each do |part|
        result << "[#{format_action(part[:action])}] #{format_address(part[:address])}"
      end
      result
    end

    def sensitive_summary(before_value, after_value)
      # before vs after
      if before_value && after_value
        "(#{Paint['sensitive', :yellow]})"
      elsif before_value
        "(#{Paint['-sensitive', :red]})"
      elsif after_value
        "(#{Paint['+sensitive', :cyan]})"
      end
    end

    def output_summary
      result = []
      output_parts.each do |part|
        pieces = [
          "[#{format_action(part[:action])}]",
          format_address("output.#{part[:address]}"),
          part[:after_unknown] ? "(unknown)" : nil,
          sensitive_summary(*part[:sensitive])
        ].compact
        result << pieces.join(" ")
      end
      result
    end

    def nested_summary # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
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
          message = "[#{format_action(part[:action])}]#{indent} #{format_address(part[:address])}"
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
          label = "[#{format_action(part[:action])}] #{format_address(part[:address])}"
          menu.choice label, part[:address]
        end
      }

      if result.empty?
        throw :abort, "nothing selected"
      else
        log "Re-running apply with the selected resources ..."
        MuxTf::Cli::Current.run_plan(targets: result)
      end
    end

    private

    attr_reader :parts

    def create_plan(filename, targets: [])
      log "Preparing Plan ...", depth: 1
      exit_code, meta = PlanFormatter.pretty_plan(filename, targets: targets)
      case exit_code
      when 0
        [:ok, meta]
      when 1
        [:error, meta]
      when 2
        [:changes, meta]
      else
        log Paint["terraform plan exited with an unknown exit code: #{exit_code}", :yellow]
        [:unknown, meta]
      end
    end

    def prune_unchanged_deps(_parts)
      valid_addresses = resource_parts.map { |part| part[:address] }

      resource_parts.each do |part|
        part[:deps].select! { |dep| valid_addresses.include?(dep) }
      end
    end

    def find_deps(data, address) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
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
        resource["expressions"]&.each do |_k, v|
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

    def color_for_action(action)
      case action
      when "create"
        :green
      when "update"
        :yellow
      when "delete"
        :red
      when "replace" # rubocop:disable Lint/DuplicateBranch
        :red
      when "replace (create before delete)" # rubocop:disable Lint/DuplicateBranch
        :red
      when "read"
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
      else
        action
      end
    end

    def format_action(action)
      color = color_for_action(action)
      symbol = symbol_for_action(action)
      Paint[symbol, color]
    end

    def format_address(address)
      result = []
      parts = ResourceTokenizer.tokenize(address)
      parts.each_with_index do |(part_type, part_value), index|
        case part_type
        when :rt
          result << "." if index.positive?
          result << Paint[part_value, :cyan]
        when :rn
          result << "."
          result << part_value
        when :ri
          result << Paint[part_value, :green]
        end
      end
      result.join
    end
  end
end
