#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark for HTML escaping — the per-output hot path of ERB rendering.
#
# Compares the native Rust escaper against the stdlib `CGI.escapeHTML` (a C
# extension) and `ERB::Util.html_escape`, across content with different ratios
# of escapable characters. Also measures a "render-like" workload that escapes
# many small fields, which is closer to what Action View does per template.
#
# Run with:
#   bundle exec ruby benchmark/html_escape_bench.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "benchmark/ips"
require "cgi/escape"
require "renderhive"

puts "Renderhive native extension loaded: #{Renderhive.native?}"
puts "Ruby: #{RUBY_DESCRIPTION}"
puts

SAMPLES = {
  "no specials (typical text)" => "Lorem ipsum dolor sit amet consectetur " * 16,
  "light (~2% specials)"       => ("word " * 40 + "<b>x</b> & y ") * 4,
  "heavy (markup soup)"        => %(<div class="card" data-id='42'><a href="/x?a=1&b=2">link & more</a></div>) * 8
}.freeze

SAMPLES.each do |label, sample|
  # Correctness gate.
  if Renderhive.native?
    raise "native mismatch (#{label})" unless Renderhive::HTML.escape(sample) == CGI.escapeHTML(sample)
  end

  puts "== #{label} (#{sample.bytesize} bytes) =="
  Benchmark.ips do |x|
    x.config(time: 3, warmup: 1)
    x.report("CGI.escapeHTML")        { CGI.escapeHTML(sample) }
    x.report("ERB::Util.html_escape") { ERB::Util.html_escape(sample) }
    x.report("Renderhive::HTML.escape") { Renderhive::HTML.escape(sample) }
    x.compare!
  end
  puts
end

# Render-like workload: escape a row of small fields, many rows.
fields = [ "Acme & Co", "Sedan <Premium>", "R$ 99.999,00", "2024", "ACTIVE" ].freeze
rows = 1_000

puts "== render-like: #{rows} rows x #{fields.size} fields =="
Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report("ERB::Util.html_escape") do
    rows.times { fields.each { |f| ERB::Util.html_escape(f) } }
  end
  x.report("Renderhive::HTML.escape") do
    rows.times { fields.each { |f| Renderhive::HTML.escape(f) } }
  end
  x.compare!
end
