# frozen_string_literal: true

# Demonstrates the in-request fragment de-duplication win: when many records
# render to the same HTML, we render ONE representative per distinct key and
# reuse it, instead of re-rendering identical output for every record.
#
#   bundle exec ruby benchmark/dedup_bench.rb

require "benchmark/ips"
require_relative "../lib/renderhive"

puts "Renderhive native extension loaded: #{Renderhive.native?}"

# A record whose rendered HTML depends only on :status (low cardinality).
Row = Struct.new(:id, :status)

STATUSES = %w[active inactive pending archived blocked].freeze

# Stand-in for the per-record render cost (template eval + escaping). It is
# intentionally non-trivial so the benchmark reflects real rendering work.
def render_row(row)
  label = "#{row.status} (#{row.status.length})"
  escaped = Renderhive::HTML.escape("<span class=\"badge\">#{label} & ok</span>")
  ActiveSupport::SafeBuffer.new("<tr><td>#{escaped}</td></tr>")
end

def build_collection(size, cardinality)
  Array.new(size) { |i| Row.new(i + 1, STATUSES[i % cardinality]) }
end

def render_full(collection)
  parts = collection.map { |row| render_row(row) }
  Renderhive::Buffer.join(parts)
end

def render_deduped(collection, &dedup)
  html_by_key = {}
  parts = collection.map do |row|
    key = dedup.call(row)
    (html_by_key[key] ||= render_row(row))
  end
  Renderhive::Buffer.join(parts)
end

dedup_key = ->(row) { row.status }

[ [ 1000, 5 ], [ 1000, 2 ], [ 5000, 5 ] ].each do |size, cardinality|
  collection = build_collection(size, cardinality)

  # Sanity: both strategies must produce identical output.
  unless render_full(collection) == render_deduped(collection, &dedup_key)
    raise "dedup output mismatch for size=#{size} cardinality=#{cardinality}"
  end

  puts "\n== #{size} rows, #{cardinality} distinct outputs =="
  Benchmark.ips do |x|
    x.report("full render (#{size}x)") { render_full(collection) }
    x.report("deduped (#{cardinality}x)") { render_deduped(collection, &dedup_key) }
    x.compare!
  end
end
