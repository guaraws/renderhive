require "active_support/core_ext/string/output_safety"

module Renderhive
  # Concatenates pre-rendered HTML fragments into a single `SafeBuffer`.
  #
  # When the optional Rust extension is available the join happens in native
  # code with a single allocation (and a parallel, off-GVL memory copy for large
  # payloads). Otherwise a pure-Ruby fallback is used, so the gem keeps working
  # on platforms without a Rust toolchain.
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
        joined = Renderhive::Native.join_buffers(parts)
        # The native join works at the byte level and returns an ASCII-8BIT
        # string; Rails view output is UTF-8, and concatenating UTF-8 byte
        # sequences yields valid UTF-8, so we restore that encoding.
        joined.force_encoding(Encoding::UTF_8)
        ActiveSupport::SafeBuffer.new(joined)
      else
        out = ActiveSupport::SafeBuffer.new
        parts.each { |part| out << part }
        out
      end
    end
  end
end
