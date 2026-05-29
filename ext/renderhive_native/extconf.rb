# frozen_string_literal: true

require "mkmf"
require "rb_sys/mkmf"

# Builds the `renderhive_native` Rust crate and installs the resulting shared
# object under `lib/renderhive/`, so it can be loaded with
# `require "renderhive/renderhive_native"`.
create_rust_makefile("renderhive/renderhive_native")
