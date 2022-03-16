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
              backup[key] = ENV[key]
              ENV.delete(key)
            end
            yield
          end
        ensure
          backup.each do |k, v|
            ENV[k] = v
          end
        end

        def run(_args)
          Dotenv.load(".env.mux")

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
          dirs.reject! { |d| d.in?(ignored) }

          dirs
        end
      end
    end
  end
end
