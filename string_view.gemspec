# frozen_string_literal: true

require_relative "lib/string_view/version"

Gem::Specification.new do |spec|
  spec.name = "string_view"
  spec.version = StringView::VERSION
  spec.authors = ["Ufuk Kayserilioglu"]
  spec.email = ["ufuk@paralaus.com"]

  spec.summary = "Zero-copy string slicing for Ruby via a C extension."
  spec.description = "StringView provides a read-only, zero-copy view into a frozen " \
                     "Ruby String, avoiding intermediate allocations for slicing, " \
                     "searching, and delegation of transform methods."
  spec.homepage = "https://github.com/Shopify/string_view"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Shopify/string_view"

  # Specify which files should be added to the gem when it is released.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/string_view/extconf.rb"]

  spec.add_dependency "rake-compiler"
end
