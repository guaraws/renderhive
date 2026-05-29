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

  def test_join_handles_large_payload_above_parallel_threshold
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
end
