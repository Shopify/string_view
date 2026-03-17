# frozen_string_literal: true

require_relative "string_view/version"

begin
  # Load the precompiled binary for this Ruby version (from cibuildgem)
  ruby_version = RUBY_VERSION[/^\d+\.\d+/]
  require_relative "string_view/#{ruby_version}/string_view"
rescue LoadError
  # Fall back to the locally compiled extension
  require_relative "string_view/string_view"
end

class StringView
  # method_missing safety net:
  # Any String method we haven't implemented natively surfaces as a hard error
  # rather than silently falling through.
  def method_missing(name, *args, &block)
    if String.method_defined?(name)
      raise NotImplementedError,
        "StringView##{name} not yet implemented natively. " \
          "Call .to_s.#{name}(...) explicitly if you need it."
    else
      super
    end
  end

  def respond_to_missing?(name, include_private = false)
    # We don't claim to respond to unimplemented String methods
    if String.method_defined?(name)
      false
    else
      super
    end
  end
end
