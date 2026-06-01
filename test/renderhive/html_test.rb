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
end
