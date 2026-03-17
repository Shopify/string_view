# frozen_string_literal: true

require "mkmf"

$CFLAGS << " -std=c99 -O3 -Wall -Wextra -Wno-unused-parameter"

create_makefile("string_view/string_view")
