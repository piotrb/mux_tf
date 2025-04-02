module MuxTf
  class PlanTextSummaryHandler
    extend TerraformHelpers
    include TerraformHelpers
    include PiotrbCliUtils::Util
    include Coloring

    class << self
      def from_file(file)
        data = text_from_file(file)
        new data
      end

      def text_from_file(plan_filename)
        if File.exist?("#{plan_filename}.txt") && File.mtime("#{plan_filename}.txt").to_f >= File.mtime(plan_filename).to_f
          File.read("#{plan_filename}.txt")
        else
          puts "Inspecting Changes ... #{plan_filename}"
          data = PlanUtils.text_version_of_plan_show(plan_filename)
          File.write("#{plan_filename}.txt", data)
          data
        end
      end
    end

    def initialize(data)
      @data = data
    end

    def each_resource(&block)
      @data.split("\n\n").each do |line|
        stripped_line = pastel.strip(line.rstrip)
        if stripped_line.split("\n").size == 1
          if stripped_line.match?(/^Terraform will perform the following actions:/)
            # noop
          elsif stripped_line.match?(/^Resource Changes:/)
            # noop
          else
            puts "Unhandled line: #{stripped_line.inspect}"
          end
        elsif stripped_line.match?(/^  # .+/)
          key = stripped_line[/^  # (.+) will be/, 1]
          payload = {
            key: key,
            raw_data: line,
            stripped_data: stripped_line
          }
          block.call(key, payload)
        else
          puts "Unhandled line: #{stripped_line.inspect}"
          # multi line strings .. likely resource changes ..
        end
        # puts "---"
        # p stripped_line
      end
      # p @data
    end
  end
end
