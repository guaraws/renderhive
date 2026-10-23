require "active_support/core_ext/string/output_safety"

module Renderhive
  # Concatenates pre-rendered HTML fragments into a single `SafeBuffer`.
  #
  # When the optional Rust extension is available the join happens in native
  # code: one pre-sized UTF-8 Ruby string, each fragment memcpy'd into it.
  # Otherwise a pure-Ruby fallback keeps the gem working on platforms
  # without a Rust toolchain.
  #
  # Every fragment is expected to already be HTML-safe (each one is produced by
  # Action View's partial renderer), so the concatenated result is also marked
  # HTML-safe.
  module Buffer
    EMPTY = ActiveSupport::SafeBuffer.new.freeze

    module_function

    def join(parts)
      return EMPTY if parts.nil? || parts.empty?

      if Renderhive.native?
        # The native join copies bytes into a string already tagged UTF-8
        # (Rails view output encoding).
        ActiveSupport::SafeBuffer.new(Renderhive::Native.join_buffers(parts))
      else
        ActiveSupport::SafeBuffer.new(parts.join)
      end
    end
  end
end
