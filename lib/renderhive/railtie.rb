require "rails/railtie"

module Renderhive
  class Railtie < ::Rails::Railtie
    initializer "renderhive.shutdown_pool_on_reload" do |app|
      app.reloader.before_class_unload do
        Renderhive::Executor.shutdown!
      end
    end
  end
end
