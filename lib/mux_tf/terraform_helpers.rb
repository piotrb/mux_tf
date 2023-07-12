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

    def tf_validate
      cmd = tf_prepare_command(["validate", "-json"], need_auth: true)
      capture_terraform(cmd, json: true)
    end

    def tf_init(input: nil, upgrade: nil, reconfigure: nil, color: true, &block)
      args = []
      args << "-input=#{input.inspect}" unless input.nil?
      args << "-upgrade" unless upgrade.nil?
      args << "-reconfigure" unless reconfigure.nil?
      args << "-no-color" unless color

      cmd = tf_prepare_command(["init", *args], need_auth: true)
      stream_or_run_terraform(cmd, &block)
    end

    def tf_plan(out:, color: true, detailed_exitcode: nil, compact_warnings: false, input: nil, targets: [], &block)
      args = []
      args += ["-out", out]
      args << "-input=#{input.inspect}" unless input.nil?
      args << "-compact-warnings" if compact_warnings
      args << "-no-color" unless color
      args << "-detailed-exitcode" if detailed_exitcode
      if targets && !targets.empty?
        targets.each do |target|
          args << "-target=#{target}"
        end
      end

      cmd = tf_prepare_command(["plan", *args], need_auth: true)
      stream_or_run_terraform(cmd, &block)
    end

    def tf_show(file, json: false)
      if json
        args = ["show", "-json", file]
        cmd = tf_prepare_command(args, need_auth: true)
        capture_terraform(cmd, json: true)
      else
        args = ["show", file]
        cmd = tf_prepare_command(args, need_auth: true)
        run_terraform(cmd)
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

    def stream_or_run_terraform(args, &block)
      if block
        stream_terraform(args, &block)
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

    def stream_terraform(args, &block)
      status = run_with_each_line(args, &block)
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
      fail_with "Execution Failed! - #{result.inspect}"
    end
  end
end
