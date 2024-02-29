# frozen_string_literal: true

module MuxTf
  module TerraformHelpers
    include PiotrbCliUtils::ShellHelpers
    include PiotrbCliUtils::Util

    ResultStruct = Struct.new("TerraformResponse", :status, :success?, :output, :parsed_output, keyword_init: true)

    def tf_force_unlock(id:)
      run_terraform(tf_prepare_command(["force-unlock", "-force", id], need_auth: true))
    end

    def tf_apply(filename: nil, targets: [])
      args = []
      args << filename if filename
      if targets && !targets.empty?
        targets.each do |target|
          args << "-target=#{target}"
        end
      end

      cmd = tf_prepare_command(["apply", *args], need_auth: true)
      run_terraform(cmd)
    end

    def format_tg_log_line(line_data)
      # {
      #   "level"=>"error",
      #   "msg"=>"terraform invocation failed in /Users/piotr/Work/janepods/accounts/eks-dev/unstable-1/kluster/.terragrunt-cache/Gqer3b7TGI4swB-Nw7Pe5DUIrus/JkQqfrQedXyGMwcl4yYfGocMcvk/modules/kluster",
      #   "prefix"=>"[/Users/piotr/Work/janepods/accounts/eks-dev/unstable-1/kluster] ",
      #   "time"=>"2024-02-28T16:14:28-08:00"
      # }

      msg = ""
      msg += case line_data["level"]
             when "info"
               pastel.cyan(line_data["level"])
             when "error"
               pastel.red(line_data["level"])
             else
               line_data["level"]
             end
      msg += ": #{line_data['msg']}"
      msg += " [#{line_data['prefix']}]" if line_data["prefix"]
      msg
    end

    def handle_stderr_line(raw_line)
      # assuming that stderr is JSON and TG logs
      parsed_line = JSON.parse(raw_line)
      log format_tg_log_line(parsed_line), depth: 2
    end

    def tf_validate
      cmd = tf_prepare_command(["validate", "-json"], need_auth: true)

      stdout = ""

      stream_terraform(cmd, split_streams: true) do |(stream, raw_line)|
        case stream
        when :command
          log "Running command: #{raw_line.strip} ...", depth: 2
        when :stdout
          stdout += raw_line
        when :stderr
          handle_stderr_line(raw_line)
        end
      end

      JSON.parse(stdout)
    end

    def tf_init(input: nil, upgrade: nil, reconfigure: nil, color: true, &block)
      args = []
      args << "-input=#{input.inspect}" unless input.nil?
      args << "-upgrade" unless upgrade.nil?
      args << "-reconfigure" unless reconfigure.nil?
      args << "-no-color" unless color

      cmd = tf_prepare_command(["init", *args], need_auth: true)
      stream_terraform(cmd, split_streams: true, &block)
    end

    def tf_plan(out:, color: true, detailed_exitcode: nil, compact_warnings: false, input: nil, targets: [], json: false, split_streams: false, &block) # rubocop:disable Metrics/CyclomaticComplexity
      args = []
      args += ["-out", out]
      args << "-input=#{input.inspect}" unless input.nil?
      args << "-compact-warnings" if compact_warnings
      args << "-no-color" unless color
      args << "-detailed-exitcode" if detailed_exitcode
      args << "-json" if json
      if targets && !targets.empty?
        targets.each do |target|
          args << "-target=#{target}"
        end
      end

      cmd = tf_prepare_command(["plan", *args], need_auth: true)
      stream_or_run_terraform(cmd, split_streams: json || split_streams, &block)
    end

    def tf_show(file, json: false, capture: false)
      if json
        args = ["show", "-json", file]
        cmd = tf_prepare_command(args, need_auth: true)
        capture_terraform(cmd, json: true)
      else
        args = ["show", file]
        cmd = tf_prepare_command(args, need_auth: true)
        if capture
          capture_terraform(cmd)
        else
          run_terraform(cmd)
        end
      end
    end

    private

    def tf_base_command
      ENV.fetch("MUX_TF_BASE_CMD", "terraform")
    end

    def tf_prepare_command(args, need_auth:)
      if ENV["MUX_TF_AUTH_WRAPPER"] && need_auth
        words = Shellwords.shellsplit(ENV["MUX_TF_AUTH_WRAPPER"])
        [*words, tf_base_command, *args]
      else
        [tf_base_command, *args]
      end
    end

    def stream_or_run_terraform(args, split_streams: false, &block)
      if block
        stream_terraform(args, split_streams: split_streams, &block)
      else
        run_terraform(args)
      end
    end

    # return_status: false, echo_command: true, quiet: false, indent: 0
    def run_terraform(args, **_options)
      status = run_shell(args, return_status: true, echo_command: true, quiet: false)
      ResultStruct.new({
                         status: status,
                         success?: status.zero?
                       })
    end

    def run_with_each_line_ex(command)
      output_queue = Thread::Queue.new
      output_queue << [:command, JSON.dump(command)]
      command = join_cmd(command)
      Open3.popen3(command) do |_stdin, stdout, stderr, wait_thr|
        stdout_thread = Thread.new do
          until stdout.eof?
            raw_line = stdout.gets
            output_queue << [:stdout, raw_line]
          end
        rescue IOError
          # ignore
        end
        stderr_thread = Thread.new do
          until stderr.eof?
            raw_line = stderr.gets
            output_queue << [:stderr, raw_line]
          end
        rescue IOError
          # ignore
        end
        Thread.new do
          stdout_thread.join
          stderr_thread.join
          output_queue.close
        end
        until output_queue.closed?
          value = output_queue.pop
          yield(value) unless value.nil?
        end
        wait_thr.value # Process::Status object returned.
      end
    end

    def stream_terraform(args, split_streams: false, &block)
      status = if split_streams
                 run_with_each_line_ex(args, &block)
               else
                 run_with_each_line(args, &block)
               end
      # status is a Process::Status
      ResultStruct.new({
                         status: status.exitstatus,
                         success?: status.exitstatus.zero?
                       })
    end

    # error: true, echo_command: true, indent: 0, raise_on_error: false, detailed_result: false
    def capture_terraform(args, json: nil)
      result = capture_shell(args, error: true, echo_command: false, raise_on_error: false, detailed_result: true)
      parsed_output = JSON.parse(result.output) if json
      ResultStruct.new({
                         status: result.status,
                         success?: result.status.zero?,
                         output: result.output,
                         parsed_output: parsed_output
                       })
    rescue JSON::ParserError
      message = "Execution failed with exit code: #{result.status}"
      message += "\nOutput:\n#{result.output}" if result.output != ""
      fail_with message
    end
  end
end
