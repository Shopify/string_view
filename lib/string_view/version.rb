# frozen_string_literal: true

# Version is set here as a plain string so the gemspec can load it
# without requiring the C extension.
# The C extension defines StringView as a class, so we use `class` here.
class StringView
  VERSION = "0.1.0"
end
