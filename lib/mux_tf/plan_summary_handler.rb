# frozen_string_literal: true

module MuxTf
  class PlanSummaryHandler
    extend TerraformHelpers

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
        File.open("#{file}.json", "w") { |fh| fh.write(JSON.dump(data)) }
        data
      end
    end

    def self.from_data(data)
      new(data)
    end

    def initialize(data)
      @parts = []

      data["resource_changes"].each do |v|
        next unless v["change"]

        case v["change"]["actions"]
        when ["no-op"]
          # do nothing
        when ["create"]
          parts << {
            action: "create",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when ["update"]
          parts << {
            action: "update",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when ["delete"]
          parts << {
            action: "delete",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when %w[delete create]
          parts << {
            action: "replace",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        when ["read"]
          parts << {
            action: "read",
            address: v["address"],
            deps: find_deps(data, v["address"])
          }
        else
          puts "[??] #{v["address"]}"
          puts "UNKNOWN ACTIONS: #{v["change"]["actions"].inspect}"
          puts "TODO: update plan_summary to support this!"
        end
      end

      prune_unchanged_deps(parts)
    end

    def summary
      summary = {}
      parts.each do |part|
        summary[part[:action]] ||= 0
        summary[part[:action]] += 1
      end
      pieces = summary.map { |k, v|
        color = color_for_action(k)
        "#{Paint[v, :yellow]} to #{Paint[k, color]}"
      }

      "Plan Summary: #{pieces.join(Paint[", ", :gray])}"
    end

    def flat_summary
      result = []
      parts.each do |part|
        result << "[#{format_action(part[:action])}] #{format_address(part[:address])}"
      end
      result
    end

    def nested_summary
      result = []
      parts = parts.deep_dup
      until parts.empty?
        part = parts.shift
        if part[:deps] == []
          indent = if part[:met_deps] && !part[:met_deps].empty?
            "  "
          else
            ""
          end
          message = "[#{format_action(part[:action])}]#{indent} #{format_address(part[:address])}"
          message += " - (needs: #{part[:met_deps].join(", ")})" if part[:met_deps]
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
        parts.each do |part|
          label = "[#{format_action(part[:action])}] #{format_address(part[:address])}"
          menu.choice label, part[:address]
        end
      }

      if !result.empty?
        log "Re-running apply with the selected resources ..."
        status = tf_apply(targets: result)
        unless status.success?
          log Paint["Failed! (#{status.status})", :red]
          throw :abort, "Apply Failed! #{status.status}"
        end
      else
        throw :abort, "nothing selected"
      end
    end

    private

    attr_reader :parts

    def prune_unchanged_deps(parts)
      valid_addresses = parts.map { |part| part[:address] }

      parts.each do |part|
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
        resource = data["prior_state"]["values"]["root_module"]["resources"].find { |resource|
          address == resource["address"] && index == resource["index"]
        }
      end

      result += resource["depends_on"] if resource && resource["depends_on"]

      resource, parent_address = find_config(data["configuration"], "root_module", address, [])
      if resource
        deps = []
        resource["expressions"].each do |_k, v|
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

      if m = address.match(/^module\.([^.]+)\./)
        find_config(module_info["module_calls"], m[1], m.post_match, parent_address + ["module.#{m[1]}"])
      else
        if module_info["resources"]
          resource = module_info["resources"].find { |resource|
            address == resource["address"]
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
      when "replace"
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
      parts = address.split(".")
      parts.each_with_index do |part, index|
        parts[index] = Paint[part, :cyan] if index.odd?
      end
      parts.join(".")
    end
  end
end
