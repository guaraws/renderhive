require "test_helper"

class Renderhive::BufferTest < Minitest::Test
  def test_join_empty_returns_blank_safe_buffer
    out = Renderhive::Buffer.join([])
    assert_equal "", out
    assert out.html_safe?
  end

  def test_join_nil_returns_blank_safe_buffer
    out = Renderhive::Buffer.join(nil)
    assert_equal "", out
    assert out.html_safe?
  end

  def test_join_concatenates_in_order
    parts = [ "<li>a</li>", "<li>b</li>", "<li>c</li>" ]
    out = Renderhive::Buffer.join(parts)
    assert_equal "<li>a</li><li>b</li><li>c</li>", out
    assert out.html_safe?
  end

  def test_join_preserves_safe_buffer_fragments
    parts = [
      "<tr><td>1</td></tr>".html_safe,
      "<tr><td>2</td></tr>".html_safe
    ]
    out = Renderhive::Buffer.join(parts)
    assert_equal "<tr><td>1</td></tr><tr><td>2</td></tr>", out
    assert out.html_safe?
  end

  def test_join_handles_large_payload
    fragment = "<div class='card'>#{"x" * 256}</div>"
    parts = Array.new(2_000) { fragment }
    out = Renderhive::Buffer.join(parts)

    assert_equal fragment * 2_000, out
    assert out.html_safe?
  end

  def test_join_handles_empty_fragments_mixed_in
    parts = [ "<a>", "", "</a>", "" ]
    out = Renderhive::Buffer.join(parts)
    assert_equal "<a></a>", out
  end

  def test_join_handles_multibyte_content
    parts = [ "café ", "açúcar ", "日本語" ]
    out = Renderhive::Buffer.join(parts)
    assert_equal "café açúcar 日本語", out
  end

  def test_join_preserves_binary_bytes_and_does_not_mutate_inputs
    parts = ["a\0b".freeze, "日本語".freeze, "".freeze]
    out = Renderhive::Buffer.join(parts)
    assert_equal "a\0b日本語", out
    assert_equal Encoding::UTF_8, out.encoding
    assert_equal ["a\0b", "日本語", ""], parts
  end

  def test_join_all_empty_fragments
    assert_equal "", Renderhive::Buffer.join(["", "", ""])
  end

  def test_join_does_not_mark_invalid_bytes_as_valid_utf8
    out = Renderhive::Buffer.join([ "\xff".dup.force_encoding(Encoding::UTF_8), "<p>ok</p>" ])
    assert_equal Encoding::UTF_8, out.encoding
    refute out.valid_encoding?
  end

  def test_native_rejects_non_strings
    skip "native extension unavailable" unless Renderhive.native?
    assert_raises(TypeError) { Renderhive::Native.join_buffers(["ok", nil]) }
  end

  def test_native_join_survives_gc_compaction
    skip "native extension unavailable" unless Renderhive.native?
    parts = Array.new(5_000) { |i| "<p>#{i}</p>" }
    expected = parts.join
    GC.verify_compaction_references(double_heap: true, toward: :empty) if GC.respond_to?(:verify_compaction_references)
    assert_equal expected, Renderhive::Buffer.join(parts)
  end
end

# Run the same behavioral contract with the optional extension disabled.
class Renderhive::FallbackBufferTest < Renderhive::BufferTest
  def setup
    @native_before_test = Renderhive.native?
    Renderhive.instance_variable_set(:@native, false)
  end

  def teardown
    Renderhive.instance_variable_set(:@native, @native_before_test)
  end
end
