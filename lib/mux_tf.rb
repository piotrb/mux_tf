# frozen_string_literal: true

require_relative "./deps"

require "English"

require "shellwords"
require "optparse"
require "json"
require "open3"

require "piotrb_cli_utils"
require "stateful_parser"

require "active_support/dependencies/autoload"
require "active_support/core_ext"

require "paint"
require "pastel"
require "tty-prompt"
require "tty-table"
require "dotenv"

require_relative "./mux_tf/version"
require_relative "./mux_tf/cli"
require_relative "./mux_tf/tmux"
require_relative "./mux_tf/terraform_helpers"
require_relative "./mux_tf/plan_formatter"
require_relative "./mux_tf/version_check"
require_relative "./mux_tf/yaml_cache"
require_relative "./mux_tf/plan_summary_handler"

module MuxTf
end
