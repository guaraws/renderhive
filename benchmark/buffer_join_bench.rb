#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark for the fragment-join hot path used by Renderhive when assembling
# a pre-rendered partial collection into a single HTML buffer.
#
# Compares three strategies across collection sizes and fragment sizes:
#   * String#<<                       — plain mutable String concatenation
#   * SafeBuffer#<<                   — Rails' pure-Ruby incremental buffer
#   * Renderhive::Buffer.join (native)— single-alloc Rust join (parallel copy
#                                       for large payloads), when compiled
#
# Run with:
#   bundle exec ruby benchmark/buffer_join_bench.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "benchmark/ips"
require "renderhive"

puts "Renderhive native extension loaded: #{Renderhive.native?}"
puts "Ruby: #{RUBY_DESCRIPTION}"
puts "CPUs: #{Etc.nprocessors}"
puts

def build_fragments(count, bytes_each)
  body = "x" * bytes_each
  Array.new(count) { ActiveSupport::SafeBuffer.new << "<div class='card'>#{body}</div>" }
end

def safe_buffer_join(parts)
  out = ActiveSupport::SafeBuffer.new
  parts.each { |p| out << p }
  out
end

def string_join(parts)
  out = +""
  parts.each { |p| out << p }
  out
end

SCENARIOS = [
  { label: "200 cards x ~2KB",   count: 200,   bytes: 2_048 },
  { label: "1000 cards x ~2KB",  count: 1_000, bytes: 2_048 },
  { label: "5000 cards x ~512B", count: 5_000, bytes: 512 }
].freeze

SCENARIOS.each do |scenario|
  parts = build_fragments(scenario[:count], scenario[:bytes])
  total_kb = parts.sum(&:bytesize) / 1024.0

  # Sanity check: every strategy must produce identical bytes.
  reference = string_join(parts)
  raise "SafeBuffer mismatch" unless safe_buffer_join(parts) == reference
  if Renderhive.native?
    raise "native mismatch" unless Renderhive::Buffer.join(parts) == reference
  end

  puts "== #{scenario[:label]} (#{total_kb.round(1)} KB total) =="

  Benchmark.ips do |x|
    x.config(time: 3, warmup: 1)

    x.report("String#<<")        { string_join(parts) }
    x.report("SafeBuffer#<<")    { safe_buffer_join(parts) }
    x.report("Renderhive::Buffer.join") { Renderhive::Buffer.join(parts) }

    x.compare!
  end
  puts
end
