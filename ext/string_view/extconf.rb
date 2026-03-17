# frozen_string_literal: true

require "mkmf"

$CFLAGS << " -std=c99 -Wall -Wextra -Wno-unused-parameter"

create_makefile("string_view/string_view")
