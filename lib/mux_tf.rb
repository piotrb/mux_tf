# frozen_string_literal: true

require "English"

require "shellwords"
require "optparse"
require "json"
require "open3"
require "digest/md5"
require "tmpdir"

require "piotrb_cli_utils"
require "stateful_parser"

require "active_support/dependencies/autoload"
require "active_support/core_ext"

require "paint"
require "pastel"
require "tty-prompt"
require "tty-table"
require "dotenv"
require "hashdiff"
require "awesome_print"
require "diff/lcs"
require "diff/lcs/string"
require "diff/lcs/hunk"

require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.ignore("#{__dir__}/deps.rb")
loader.setup

module MuxTf
  ROOT = File.expand_path(File.join(__dir__, ".."))
end

loader.eager_load
