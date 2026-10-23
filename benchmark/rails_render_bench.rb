# frozen_string_literal: true

# End-to-end benchmark: a real ActionController + ActionView stack rendering
# an index page with a partial collection, with and without Renderhive.
#
# Templates live in memory (ActionView::FixtureResolver) so the numbers
# measure rendering, not disk I/O. Two partial flavours are exercised:
#   * cpu — pure ERB (interpolation + escaping), GVL bound
#   * mixed — every 10th card adds a ~50 µs blocking call (~40% off-GVL)
#   * io  — same ERB plus a simulated 0.2 ms blocking call per card (stands in
#           for a lazy association / cache read that releases the GVL)
#
#   bundle exec ruby benchmark/rails_render_bench.rb
#   SIZES=200,1000 BENCH_RUNS=30 bundle exec ruby benchmark/rails_render_bench.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "action_controller"
require "action_view"
require "action_view/testing/resolvers"
require "renderhive"

Card = Struct.new(:id, :name, :brand, :price, :tags) do
  def to_partial_path = "cards/card"
end

CARD_PARTIAL = <<~ERB
  <article class="card" id="card-<%= card.id %>">
    <h2 class="card__title"><%= card.name %></h2>
    <p class="card__brand"><%= card.brand %> &mdash; <%= card.price %></p>
    <ul class="card__tags"><% card.tags.each do |tag| %><li><%= tag %></li><% end %></ul>
    <% sleep(BLOCKING[:sleep]) if BLOCKING[:sleep] && (card.id % BLOCKING[:every]).zero? %>
  </article>
ERB

TEMPLATES = {
  "cards/_card.html.erb" => CARD_PARTIAL,
  "cards/index.html.erb" => "<main><%= render @cards %></main>",
  "cards/fast.html.erb" => "<main><%= renderhive_collection(:cards) { render @cards } %></main>"
}.freeze

def build_controller(parallel:, delivery: :fragments)
  Class.new(ActionController::Base) do
    include Renderhive::ViewParallelism if parallel

    self.view_paths = [ ActionView::FixtureResolver.new(TEMPLATES) ]

    define_singleton_method(:name) { "CardsController" }
    define_singleton_method(:controller_path) { "cards" }

    if parallel
      parallelize_partial_collection :cards, only: %i[index fast], delivery: delivery
    end

    define_method(:index) { @cards = CARDS.fetch(params[:size].to_i) }
    define_method(:fast) { @cards = CARDS.fetch(params[:size].to_i) }
  end
end

def build_cards(count)
  Array.new(count) do |i|
    Card.new(i + 1, "Car <#{i}> & co", "Brand #{i % 17}", format("$%.2f", i * 13.37), %w[new used "promo"].first(1 + (i % 3)))
  end.freeze
end

# kind => simulated blocking call: duration and how often (every Nth card).
KINDS = {
  cpu: { sleep: nil, every: 1 },
  mixed: { sleep: 0.00005, every: 10 },
  io: { sleep: 0.0002, every: 1 }
}.freeze
BLOCKING = {}
SIZES = ENV.fetch("SIZES", "200,1000").split(",").map(&:to_i)
CARDS = SIZES.to_h { |size| [ size, build_cards(size) ] }
RUNS = ENV.fetch("BENCH_RUNS", 20).to_i
WARMUP = 3

def call(controller, action, size)
  env = Rack::MockRequest.env_for("/cards/#{action}?size=#{size}", "HTTP_ACCEPT" => "text/html")
  status, _headers, body = controller.action(action).call(env)
  raise "status #{status}" unless status == 200

  out = +""
  body.each { |chunk| out << chunk }
  out
end

def measure(controller, action, size)
  WARMUP.times { call(controller, action, size) }
  GC.start
  times = Array.new(RUNS) do
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    call(controller, action, size)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
  end.sort
  { avg: times.sum / times.size, p50: times[times.size / 2], min: times.first }
end

puts "Renderhive native: #{Renderhive.native?}  #{RUBY_DESCRIPTION}  CPUs: #{Etc.nprocessors}"

ENV.fetch("KINDS", KINDS.keys.join(",")).split(",").map(&:to_sym).each do |kind|
  BLOCKING.replace(KINDS.fetch(kind))
  serial = build_controller(parallel: false)
  parallel = build_controller(parallel: true)
  collection = build_controller(parallel: true, delivery: :collection)

  SIZES.each do |size|
    expected = call(serial, :index, size)
    raise "fragments output mismatch (#{kind}/#{size})" unless call(parallel, :index, size) == expected
    raise "collection output mismatch (#{kind}/#{size})" unless call(collection, :fast, size) == expected

    base = measure(serial, :index, size)
    rows = {
      "serial" => base,
      "renderhive fragments" => measure(parallel, :index, size),
      "renderhive collection" => measure(collection, :fast, size)
    }

    puts "\n== #{kind} partial, #{size} cards (#{expected.bytesize / 1024} KB) =="
    rows.each do |label, r|
      puts format("  %-24s avg=%8.2fms p50=%8.2fms min=%8.2fms  %5.2fx", label, r[:avg], r[:p50], r[:min], base[:p50] / r[:p50])
    end
  end
end

Renderhive::Executor.shutdown!
