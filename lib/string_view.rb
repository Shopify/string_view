# frozen_string_literal: true

require_relative "string_view/version"
require_relative "string_view/string_view"

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
