require_relative "lib/renderhive/version"

Gem::Specification.new do |spec|
  spec.name          = "renderhive"
  spec.version       = Renderhive::VERSION
  spec.authors       = [ "Fellipe" ]
  spec.email         = [ "fellipe@example.com" ]

  spec.summary       = "Parallel pre-rendering of Rails partial collections and helper methods."
  spec.description   = <<~DESC
    Renderhive is a tiny Rails concern that pre-computes controller helper
    methods and pre-renders partial collections concurrently across a
    persistent thread pool, then transparently swaps the results into the
    normal view rendering path — no changes to existing templates required.
  DESC
  spec.homepage      = "https://github.com/CHANGE_ME/renderhive"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rs,toml,rb}",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]
  spec.require_paths = [ "lib" ]
  spec.extensions = [ "ext/renderhive_native/extconf.rb" ]

  spec.add_dependency "actionpack",     ">= 7.0"
  spec.add_dependency "actionview",     ">= 7.0"
  spec.add_dependency "activesupport",  ">= 7.0"
  spec.add_dependency "concurrent-ruby", ">= 1.2"
  spec.add_dependency "rb_sys",          ">= 0.9"
end
