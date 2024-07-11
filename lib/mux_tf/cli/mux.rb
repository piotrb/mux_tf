# frozen_string_literal: true

require "bundler"

module MuxTf
  module Cli
    module Mux
      extend PiotrbCliUtils::Util
      extend PiotrbCliUtils::ShellHelpers

      class << self
        def with_clean_env
          backup = {}
          Bundler.with_original_env do
            ENV.keys.grep(/^(RBENV_|RUBYLIB)/).each do |key|
              backup[key] = ENV.fetch(key)
              ENV.delete(key)
            end
            yield
          end
        ensure
          backup.each do |k, v|
            ENV[k] = v
          end
        end

        def run(args)
          if ENV["MUX_V2"]
            run_v2(args)
          else
            run_v1(args)
          end
        end

        def run_create_session
          project = File.basename(Dir.getwd)

          if Tmux.session_running?(project)
            log "Killing existing session ..."
            Tmux.kill_session(project)
          end

          log "Starting new session ..."
          with_clean_env do
            Tmux.new_session project
          end
          Tmux.select_pane "initial"

          window_id = Tmux.list_windows.first[:id]

          Tmux.set "remain-on-exit", "on"

          Tmux.set_hook "pane-exited", "select-layout tiled"
          Tmux.set_hook "window-pane-changed", "select-layout tiled"
          Tmux.set_hook "pane-exited", "select-layout tiled"

          Tmux.set "mouse", "on"

          puts "\e]0;tmux: #{project}\007"

          Tmux.split_window :horizontal, "#{project}:#{window_id}", cwd: Dir.getwd,
                                                                    cmd: File.expand_path(File.join(__dir__, "..", "..", "..", "exe", "tf_mux spawner"))
          Tmux.select_pane "spawner"

          initial_pane = Tmux.find_pane("initial")
          Tmux.kill_pane initial_pane[:id]
          Tmux.tile!

          log "Attaching ..."
          Tmux.attach(project)
          log "Done!"
        end

        def parse_control_line(line)
          keyword, remainder = line.split(" ", 2)
          case keyword
          when "%begin"
            # n1, n2, n3, remainder = remainder.split(" ", 4)
            p [:begin, n1, n2, n3, remainder]
          when "%end"
            # n1, n2, n3, remainder = remainder.split(" ", 4)
            p [:end, n1, n2, n3, remainder]
          when "%session-changed"
            # n1, s1, remainder = remainder.split(" ", 3)
            # p [:session_changed, n1, s1, remainder]
          when "%window-pane-changed"
            # n1, n2, remainder = remainder.split(" ", 3)
            # p [:window_pane_changed, n1, n2, remainder]
          when "%layout-change"
            # ignore
            # p [:layout_change, remainder]
          when "%pane-mode-changed"
            # ignore
            p [:layout_change, remainder]
          when "%subscription-changed"
            sub_name, n1, n2, n3, n4, _, remainder = remainder.split(" ", 7)
            if sub_name == "pane-info"
              pane_id, pane_index, pane_title, pane_dead_status = remainder.strip.split(",", 4)
              if pane_dead_status != ""
                p [:pane_exited, pane_id, pane_index, pane_title, pane_dead_status]
                Tmux.kill_pane(pane_id)
                panes = Tmux.list_panes
                if panes.length == 1 && panes.first[:name] == "spawner"
                  Tmux.kill_pane(panes.first[:id])
                  # its the last pane, so the whole thing should exit
                end
              end
            else
              p [:subscription_changed, sub_name, n1, n2, n3, n4, remainder]
            end
          when "%output"
            pane, = remainder.split(" ", 2)
            if pane == "%1"
              # skip own output
              # else
              #   p [:output, pane, remainder]
            end
          else
            p [keyword, remainder]
          end
        end

        def run_spawner
          project = File.basename(Dir.getwd)

          control_thread = Thread.new do
            puts "Control Thread Started"
            Tmux.attach_control(project, on_spawn: lambda { |stdin|
              stdin.write("refresh-client -B \"pane-info:%*:\#{pane_id},\#{pane_index},\#{pane_title},\#{pane_dead_status}\"\n")
              stdin.flush
            }, on_line: lambda { |stream, line|
              if stream == :stdout
                parse_control_line(line)
                # p info
              else
                p [stream, line]
              end
            })
            puts "Control Thread Exited"
          end

          begin
            log "Enumerating folders ..."
            dirs = enumerate_terraform_dirs

            fail_with "Error: - no subfolders detected! Aborting." if dirs.empty?

            tasks = dirs.map { |dir|
              {
                name: dir,
                cwd: dir,
                cmd: File.expand_path(File.join(__dir__, "..", "..", "..", "exe", "tf_current"))
              }
            }

            if ENV["MUX_TF_AUTH_WRAPPER"]
              log "Warming up AWS connection ..."
              words = Shellwords.shellsplit(ENV["MUX_TF_AUTH_WRAPPER"])
              result = capture_shell([*words, "aws", "sts", "get-caller-identity"], raise_on_error: true)
              p JSON.parse(result)
            end

            window_id = Tmux.list_windows.first[:id]

            return if tasks.empty?

            tasks.each do |task|
              log "launching task: #{task[:name]} ...", depth: 2
              Tmux.split_window :horizontal, "#{project}:#{window_id}", cmd: task[:cmd], cwd: task[:cwd]
              Tmux.select_pane task[:name]
              Tmux.tile!
              task[:commands]&.each do |cmd|
                Tmux.send_keys cmd, enter: true
              end
            end
          ensure
            control_thread.join
          end
        end

        def run_v2(args)
          Dotenv.load(".env.mux")

          if args[0] == "spawner"
            run_spawner
          else
            run_create_session
          end
        end

        def run_v1(_args)
          Dotenv.load(".env.mux")

          dirs = enumerate_terraform_dirs

          tasks = dirs.map { |dir|
            {
              name: dir,
              cwd: dir,
              cmd: File.expand_path(File.join(__dir__, "..", "..", "..", "exe", "tf_current"))
            }
          }

          project = File.basename(Dir.getwd)

          if ENV["MUX_TF_AUTH_WRAPPER"]
            log "Warming up AWS connection ..."
            words = Shellwords.shellsplit(ENV["MUX_TF_AUTH_WRAPPER"])
            result = capture_shell([*words, "aws", "sts", "get-caller-identity"], raise_on_error: true)
            p JSON.parse(result)
          end

          if Tmux.session_running?(project)
            log "Killing existing session ..."
            Tmux.kill_session(project)
          end

          log "Starting new session ..."
          with_clean_env do
            Tmux.new_session project
          end
          Tmux.select_pane "initial"

          # Tmux.set "remain-on-exit", "on"

          Tmux.set_hook "pane-exited", "select-layout tiled"
          Tmux.set_hook "window-pane-changed", "select-layout tiled"

          Tmux.set "mouse", "on"

          window_id = Tmux.list_windows.first[:id]

          unless tasks.empty?
            tasks.each do |task|
              log "launching task: #{task[:name]} ...", depth: 2
              Tmux.split_window :horizontal, "#{project}:#{window_id}", cmd: task[:cmd], cwd: task[:cwd]
              Tmux.select_pane task[:name]
              Tmux.tile!
              task[:commands]&.each do |cmd|
                Tmux.send_keys cmd, enter: true
              end
            end
          end

          log "Almost done ..."

          initial_pane = Tmux.find_pane("initial")
          Tmux.kill_pane initial_pane[:id]
          Tmux.tile!

          puts "\e]0;tmux: #{project}\007"

          sleep 1

          log "Attaching ..."
          Tmux.attach(project, cc: !!ENV["MUXP_CC_MODE"])
          log "Done!"
        end

        private

        def enumerate_terraform_dirs
          ignored = []

          ignored += ENV["MUX_IGNORE"].split(",") if ENV["MUX_IGNORE"]

          dirs = Dir["**/.terraform.lock.hcl"].map { |f| File.dirname(f) }
          dirs.reject! do |d|
            d.in?(ignored)
          end

          dirs
        end
      end
    end
  end
end
