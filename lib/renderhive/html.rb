require "erb"
require "cgi/escape"
require "active_support/core_ext/string/output_safety"

module Renderhive
  # Native-accelerated HTML escaping that mirrors `ERB::Util.html_escape`.
  #
  # `escape` is the raw escaping primitive: it always escapes and returns a
  # plain (non-`html_safe`) UTF-8 String, just like `CGI.escapeHTML`. When the
  # Rust extension is unavailable it falls back to `CGI.escapeHTML`.
  #
  # `unwrapped_html_escape` mirrors Action View's output-escaping semantics
  # (honours the `html_safe` short-circuit and returns a `SafeBuffer`). It is a
  # building block: wiring it into a host app's view layer is an explicit,
  # opt-in decision left to the application, so Renderhive never patches global
  # Rails/Ruby internals on its own.
  module HTML
    module_function

    # Raw escape primitive. Returns a plain String (not html_safe).
    def escape(value)
      string = value.to_s

      if Renderhive.native?
        # Returns the same object when nothing needs escaping; otherwise a new
        # string carrying the input's encoding, like CGI.escapeHTML.
        Renderhive::Native.escape_html(string)
      else
        CGI.escapeHTML(string)
      end
    end

    # Mirrors ERB::Util.unwrapped_html_escape: honours the html_safe
    # short-circuit and returns an html_safe buffer.
    def unwrapped_html_escape(value)
      string = value.to_s
      return string if string.html_safe?

      ActiveSupport::SafeBuffer.new(escape(string))
    end
  end
end
