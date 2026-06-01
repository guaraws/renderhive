require "active_support"
require "active_support/concern"
require "active_support/core_ext/class/attribute"
require "active_support/notifications"

require "renderhive/version"
require "renderhive/executor"
require "renderhive/buffer"
require "renderhive/html"
require "renderhive/view_parallelism"
require "renderhive/railtie" if defined?(Rails::Railtie)

module Renderhive
  @native = begin
    require "renderhive/renderhive_native"
    true
  rescue LoadError
    false
  end

  # Whether the optional Rust extension was compiled and loaded successfully.
  # When false, Renderhive transparently falls back to its pure-Ruby paths.
  def self.native?
    @native
  end
end
