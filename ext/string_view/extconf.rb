# frozen_string_literal: true

require "mkmf"

# C flags for string_view.c
$CFLAGS << " -std=c99 -O3 -Wall -Wextra -Wno-unused-parameter"

# C++ flags for simdutf
$CXXFLAGS = " -std=c++17 -O3 -DNDEBUG"

# Tell mkmf about our source files (C and C++ mixed)
$srcs = %w[string_view.c simdutf.cpp]
$INCFLAGS << " -I$(srcdir)"

create_makefile("string_view/string_view")
