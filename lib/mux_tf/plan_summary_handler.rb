# frozen_string_literal: true

module MuxTf
  class PlanSummaryHandler
    extend TerraformHelpers
    include TerraformHelpers
    include PiotrbCliUtils::Util

    PLAN_FILENAME = "foo.tfplan"

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
        run_plan(targets: result)
      else
        throw :abort, "nothing selected"
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

    def run_plan(targets: [])
      plan_status, @plan_meta = create_plan(PLAN_FILENAME, targets: targets)

      case plan_status
      when :ok
        log "no changes", depth: 1
      when :error
        log "something went wrong", depth: 1
      when :changes
        log "Printing Plan Summary ...", depth: 1
        pretty_plan_summary(PLAN_FILENAME)
      when :unknown
        # nothing
      end
      plan_status
    end

    def pretty_plan_summary(filename)
      plan = PlanSummaryHandler.from_file(filename)
      plan.flat_summary.each do |line|
        log line, depth: 2
      end
      log "", depth: 2
      log plan.summary, depth: 2
    end

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
      result = []
      parts = ResourceTokenizer.tokenize(address)
      parts.each_with_index do |(part_type, part_value), index|
        case part_type
        when :rt
          result << "." if index > 0
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
