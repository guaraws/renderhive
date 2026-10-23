require "test_helper"
require "cgi/escape"

class Renderhive::HTMLTest < Minitest::Test
  def test_escape_matches_cgi_for_special_chars
    raw = %(<a href="x" data-q='&'>1 < 2 & 3 > 0</a>)
    assert_equal CGI.escapeHTML(raw), Renderhive::HTML.escape(raw)
  end

  def test_escape_each_entity
    assert_equal "&amp;", Renderhive::HTML.escape("&")
    assert_equal "&lt;", Renderhive::HTML.escape("<")
    assert_equal "&gt;", Renderhive::HTML.escape(">")
    assert_equal "&quot;", Renderhive::HTML.escape('"')
    assert_equal "&#39;", Renderhive::HTML.escape("'")
  end

  def test_escape_returns_unchanged_when_nothing_to_escape
    raw = "plain text without specials"
    assert_equal raw, Renderhive::HTML.escape(raw)
  end

  def test_escape_preserves_utf8
    raw = "café & açúcar < 日本語"
    out = Renderhive::HTML.escape(raw)
    assert_equal CGI.escapeHTML(raw), out
    assert_equal Encoding::UTF_8, out.encoding
  end

  def test_escape_handles_empty_string
    assert_equal "", Renderhive::HTML.escape("")
  end

  def test_escape_coerces_non_strings
    assert_equal "1 &lt; 2", Renderhive::HTML.escape("1 < 2")
    assert_equal "123", Renderhive::HTML.escape(123)
  end

  def test_unwrapped_html_escape_returns_safe_buffer
    out = Renderhive::HTML.unwrapped_html_escape("a < b")
    assert_equal "a &lt; b", out
    assert out.html_safe?
  end

  def test_unwrapped_html_escape_short_circuits_safe_strings
    safe = "<b>bold</b>".html_safe
    assert_equal "<b>bold</b>", Renderhive::HTML.unwrapped_html_escape(safe)
  end

  def test_escape_matches_cgi_at_every_block_offset
    specials = [ "&", "<", ">", '"', "'" ]
    (0..48).each do |len|
      specials.each do |special|
        (0...len).step(3) do |pos|
          raw = "a" * len
          raw[pos] = special
          raw << "é" if pos.even?
          assert_equal CGI.escapeHTML(raw), Renderhive::HTML.escape(raw), "len=#{len} pos=#{pos} #{special}"
        end
      end
    end
  end

  def test_escape_matches_cgi_on_dense_markup
    raw = %(<div class="c" data-x='1'><a href="/?a=1&b=2">x & y</a></div>) * 37
    assert_equal CGI.escapeHTML(raw), Renderhive::HTML.escape(raw)
  end

  def test_escape_preserves_input_encoding_and_validity
    invalid = "\xff<b>".dup.force_encoding(Encoding::UTF_8)
    out = Renderhive::HTML.escape(invalid)
    assert_equal Encoding::UTF_8, out.encoding
    refute out.valid_encoding?

    binary = "<\xff>".b
    assert_equal CGI.escapeHTML(binary).encoding, Renderhive::HTML.escape(binary).encoding
  end
end
