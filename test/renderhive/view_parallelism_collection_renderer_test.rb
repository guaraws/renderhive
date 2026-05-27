require "test_helper"

class Renderhive::ViewParallelismCollectionRendererTest < Minitest::Test
  class FakeController
    attr_reader :prepare_calls

    def initialize(collection_html: nil)
      @prepare_calls = 0
      @_renderhive_collection_html = collection_html
    end

    private

    def renderhive_prepare_parallel_view_workload
      @prepare_calls += 1
    end
  end

  class FakeView
    include Renderhive::ViewParallelism::CollectionRenderer

    attr_reader :controller

    def initialize(controller)
      @controller = controller
    end

    def capture(&block)
      block.call
    end
  end

  def test_renderhive_collection_returns_pre_rendered_html
    html = ActiveSupport::SafeBuffer.new << "<tr><td>ok</td></tr>"
    controller = FakeController.new(collection_html: { customers: html })
    view = FakeView.new(controller)

    assert_same html, view.renderhive_collection(:customers) { "fallback" }
    assert_equal 1, controller.prepare_calls
  end

  def test_renderhive_collection_falls_back_to_block_when_missing_html
    controller = FakeController.new(collection_html: {})
    view = FakeView.new(controller)

    assert_equal "fallback", view.renderhive_collection(:customers) { "fallback" }
    assert_equal 1, controller.prepare_calls
  end
end