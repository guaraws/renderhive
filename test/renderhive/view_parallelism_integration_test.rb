require "test_helper"
require "action_controller"
require "action_view"
require "action_view/testing/resolvers"

# Renders through a real ActionController + ActionView stack and compares the
# HTML byte-for-byte with plain serial Rails rendering.
class Renderhive::ViewParallelismIntegrationTest < Minitest::Test
  Item = Struct.new(:id, :name) do
    def to_partial_path = "items/item"
  end

  RENDERS = Concurrent::AtomicFixnum.new
  ITEMS = Array.new(40) { |i| Item.new(i + 1, "Item <#{i}> & co") }.freeze

  TEMPLATES = {
    "items/_item.html.erb" => %(<% Renderhive::ViewParallelismIntegrationTest::RENDERS.increment %><li id="i<%= item.id %>"><%= item.name %></li>\n),
    "items/implicit.html.erb" => "<ul><%= render @items %></ul>",
    "items/explicit.html.erb" => %(<ul><%= render partial: "items/item", collection: @items, as: :item %></ul>),
    "items/each.html.erb" => "<ul><% @items.each do |item| %><%= render item %><% end %></ul>",
    "items/subset.html.erb" => "<ul><%= render @items.first(3) %></ul>",
    "items/helper.html.erb" => "<ul><%= renderhive_collection(:items) { render @items } %></ul>"
  }.freeze

  ACTIONS = %i[ implicit explicit each subset helper ].freeze

  def teardown
    Renderhive::Executor.shutdown!
  end

  def build_controller(parallel:, delivery: :fragments)
    Class.new(ActionController::Base) do
      include Renderhive::ViewParallelism if parallel

      self.view_paths = [ ActionView::FixtureResolver.new(TEMPLATES) ]
      define_singleton_method(:name) { "ItemsController" }
      define_singleton_method(:controller_path) { "items" }

      parallelize_partial_collection :items, delivery: delivery, max_threads: 4, workload: :io if parallel

      ACTIONS.each { |action| define_method(action) { @items = ITEMS } }
    end
  end

  def render_action(controller, action)
    env = Rack::MockRequest.env_for("/items/#{action}", "HTTP_ACCEPT" => "text/html")
    status, _headers, body = controller.action(action).call(env)
    assert_equal 200, status

    html = +""
    body.each { |chunk| html << chunk }
    html
  end

  def renders_during
    before = RENDERS.value
    yield
    RENDERS.value - before
  end

  def expected_html
    @expected_html ||= begin
      serial = build_controller(parallel: false)
      (ACTIONS - %i[ helper ]).to_h { |action| [ action, render_action(serial, action) ] }
        .merge(helper: render_action(serial, :implicit))
    end
  end

  %i[ fragments collection both ].each do |delivery|
    ACTIONS.each do |action|
      define_method(:"test_#{delivery}_#{action}_matches_serial_rails_output") do
        controller = build_controller(parallel: true, delivery: delivery)

        assert_equal expected_html.fetch(action), render_action(controller, action)
      end
    end

    define_method(:"test_#{delivery}_render_collection_renders_each_record_once") do
      controller = build_controller(parallel: true, delivery: delivery)

      %i[ implicit explicit helper ].each do |action|
        assert_equal ITEMS.size, renders_during { render_action(controller, action) }, action
      end
    end
  end

  def test_subset_falls_back_to_a_regular_render
    controller = build_controller(parallel: true)

    # 40 pre-rendered + 3 rendered normally for the records the view asked for.
    assert_equal ITEMS.size + 3, renders_during { render_action(controller, :subset) }
  end
end
