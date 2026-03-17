# frozen_string_literal: true

require_relative "lib/string_view/version"

Gem::Specification.new do |spec|
  spec.name = "string_view"
  spec.version = StringView::VERSION
  spec.authors = ["Shopify"]
  spec.email = ["ruby@shopify.com"]

  spec.summary = "Zero-copy string slicing for Ruby via a C extension."
  spec.description = "StringView provides a read-only, zero-copy view into a frozen " \
    "Ruby String, avoiding intermediate allocations for slicing, " \
    "searching, and delegation of transform methods. Uses simdutf " \
    "for SIMD-accelerated UTF-8 character counting."
  spec.homepage = "https://github.com/Shopify/string_view"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Shopify/string_view"
  spec.metadata["changelog_uri"] = "https://github.com/Shopify/string_view/releases"

  spec.files = Dir.glob([
    "LICENSE.txt",
    "LICENSE-simdutf.txt",
    "README.md",
    "Rakefile",
    "lib/**/*.rb",
    "ext/**/*.{rb,c,cpp,h}",
  ])

  spec.require_paths = ["lib"]
  spec.extensions = ["ext/string_view/extconf.rb"]
end
