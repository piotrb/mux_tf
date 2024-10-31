# frozen_string_literal: true

require "shellwords"
require "open3"

module MuxTf
  module Tmux
    extend PiotrbCliUtils::Util

    class << self
      def session_running?(name)
        tmux("has-session -t #{name.inspect} 2>/dev/null", raise_on_error: false)
      end

      def kill_session(name)
        tmux(%(kill-session -t #{name.inspect}))
      end

      def find_pane(name)
        panes = `tmux list-panes -F "\#{pane_id},\#{pane_title}"`.strip.split("\n").map { |row|
          x = row.split(",")
          { id: x[0], name: x[1] }
        }
        panes.find { |pane| pane[:name] == name }
      end

      def list_panes
        `tmux list-panes -F "\#{pane_id},\#{pane_index},\#{pane_title}"`.strip.split("\n").map do |row|
          x = row.split(",")
          { id: x[0], index: x[1], name: x[2] }
        end
      end

      def list_windows
        `tmux list-windows -F "\#{window_id},\#{window_index},\#{window_name}"`.strip.split("\n").map do |row|
          x = row.split(",")
          { id: x[0], index: x[1], name: x[2] }
        end
      end

      def new_session(name, cwd: nil, cmd: nil)
        parts = [
          "new-session",
          "-s #{name.inspect}",
          "-d",
          cwd ? "-c #{cwd}" : nil,
          cmd&.inspect
        ].compact
        tmux parts.join(" ")
      end

      def select_pane(name)
        tmux %(select-pane -T #{name.inspect})
      end

      def set_hook(hook_name, cmd)
        tmux %(set-hook #{hook_name.inspect} #{cmd.inspect})
      end

      def set(var, value)
        tmux %(set #{var.inspect} #{value.inspect})
      end

      def tile!
        tmux "select-layout tiled"
      end

      def attach_control(name, on_line:, on_spawn:)
        parts = [
          "-C",
          "attach",
          "-t #{name.inspect}"
        ].compact
        tmux parts.join(" "), raise_on_error: false, mode: :popen, on_line: on_line, on_spawn: on_spawn
      end

      def attach(name, cc: false, control: false)
        parts = [
          cc ? "-CC" : nil,
          control ? "-C" : nil,
          "attach",
          "-t #{name.inspect}"
        ].compact
        tmux parts.join(" "), raise_on_error: false
      end

      def kill_pane(pane_id)
        tmux %(kill-pane -t #{pane_id.inspect})
      end

      def send_keys(cmd, enter: false)
        tmux %(send-keys #{cmd.inspect})
        tmux %(send-keys Enter) if enter
      end

      def split_window(mode, target_pane, cwd: nil, cmd: nil)
        case mode
        when :horizontal
          mode_part = "-h"
        when :vertical
          mode_part = "-v"
        else
          raise ArgumentError, "invalid mode: #{mode.inspect}"
        end

        parts = [
          "split-window",
          cwd ? "-c #{cwd}" : nil,
          mode_part,
          "-t #{target_pane.inspect}",
          cmd&.inspect
        ].compact
        tmux parts.join(" ")
      end

      private

      def tmux_bin
        @tmux_bin ||= `which tmux`.strip
      end

      def tmux(cmd, raise_on_error: true, mode: :system, on_line: nil, on_spawn: nil)
        case mode
        when :system
          # puts " => tmux #{cmd}"
          system("#{tmux_bin} #{cmd}")
          unless $CHILD_STATUS.success?
            fail_with("`tmux #{cmd}' failed with code: #{$CHILD_STATUS.exitstatus}") if raise_on_error

            return false
          end
          true
        when :exec
          exec tmux_bin, *Shellwords.shellwords(cmd)
        when :popen
          Open3.popen3(tmux_bin, *Shellwords.shellwords(cmd)) do |stdin, stdout, stderr, wait_thr|
            on_spawn&.call(stdin, wait_thr)
            Thread.new do
              until stdout.closed? || stdout.eof?
                line = stdout.gets
                on_line&.call(:stdout, line)
              end
            end
            Thread.new do
              until stderr.closed? || stderr.eof?
                line = stderr.gets
                on_line&.call(:stderr, line)
              end
            end
            # pid = wait_thr.pid
            exit_status = wait_thr.value
            fail_with("`tmux #{cmd}' failed with code: #{exit_status}") if raise_on_error && exit_status != 0
          end
        end
      end
    end
  end
end
