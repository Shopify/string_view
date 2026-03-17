# frozen_string_literal: true

require "benchmark/ips"
require "objspace"
require_relative "../lib/string_view"

puts "Ruby #{RUBY_VERSION}  •  string_view #{StringView::VERSION}"
puts

# ===========================================================================
# Setup
# ===========================================================================

# ASCII (UTF-8 encoding, all single-byte)
ASCII_BUF = ("a" * 500_000 + "NEEDLE" + "b" * 500_000).freeze
SV_ASCII  = StringView.new(ASCII_BUF)

# Binary (ASCII-8BIT)
BINARY_BUF = (("\x00\x01\x02\xFE\xFF".b * 200_000) + "NEEDLE".b + ("\xAA\xBB".b * 100_000)).freeze
SV_BINARY  = StringView.new(BINARY_BUF)

# UTF-8 with real multibyte (CJK + emoji + accented + ASCII mix)
UTF8_BUF = ("日本語テスト🎉café hello " * 50_000).freeze
SV_UTF8  = StringView.new(UTF8_BUF)

# Pre-sliced inner regions
STR_ASCII_INNER  = ASCII_BUF[250_000, 500_000]
SV_ASCII_INNER   = SV_ASCII[250_000, 500_000]

STR_BINARY_INNER = BINARY_BUF[250_000, 500_000]
SV_BINARY_INNER  = SV_BINARY[250_000, 500_000]

utf8_chars = UTF8_BUF.length
STR_UTF8_INNER   = UTF8_BUF[utf8_chars / 4, utf8_chars / 2]
SV_UTF8_INNER    = SV_UTF8[utf8_chars / 4, utf8_chars / 2]

puts "ASCII:  #{ASCII_BUF.bytesize} bytes, #{ASCII_BUF.encoding}"
puts "Binary: #{BINARY_BUF.bytesize} bytes, #{BINARY_BUF.encoding}"
puts "UTF-8:  #{UTF8_BUF.bytesize} bytes, #{UTF8_BUF.length} chars, #{UTF8_BUF.encoding}"
puts

# ===========================================================================
# ASCII: Inner slice creation
# ===========================================================================
puts "=" * 70
puts "ASCII: Inner slice creation (1MB backing)"
puts "=" * 70
puts

[1_000, 10_000, 100_000, 500_000].each do |slice_size|
  offset = (ASCII_BUF.bytesize - slice_size) / 2
  Benchmark.ips do |x|
    x.config(warmup: 2, time: 5)
    x.report("String[#{offset}, #{slice_size}]") { ASCII_BUF[offset, slice_size] }
    x.report("SV[#{offset}, #{slice_size}]")     { SV_ASCII[offset, slice_size] }
    x.compare!
  end
  puts
end

# ===========================================================================
# ASCII: Read-only ops on pre-existing inner slice
# ===========================================================================
puts "=" * 70
puts "ASCII: Read-only ops on pre-existing 500KB inner slice"
puts "=" * 70
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#include?")      { STR_ASCII_INNER.include?("NEEDLE") }
  x.report("StringView#include?")  { SV_ASCII_INNER.include?("NEEDLE") }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#start_with?")      { STR_ASCII_INNER.start_with?("xxxxx") }
  x.report("StringView#start_with?")  { SV_ASCII_INNER.start_with?("xxxxx") }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#bytesize")      { STR_ASCII_INNER.bytesize }
  x.report("StringView#bytesize")  { SV_ASCII_INNER.bytesize }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#getbyte")      { STR_ASCII_INNER.getbyte(250_000) }
  x.report("StringView#getbyte")  { SV_ASCII_INNER.getbyte(250_000) }
  x.compare!
end
puts

# ===========================================================================
# ASCII: Combined slice + operate
# ===========================================================================
puts "=" * 70
puts "ASCII: Combined inner-slice + operate"
puts "=" * 70
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String: slice+start_with?") { ASCII_BUF[250_000, 500_000].start_with?("aaa") }
  x.report("SV: slice+start_with?")     { SV_ASCII[250_000, 500_000].start_with?("aaa") }
  x.compare!
end
puts

# ===========================================================================
# Binary: Inner slice creation
# ===========================================================================
puts "=" * 70
puts "Binary (ASCII-8BIT): Inner slice creation"
puts "=" * 70
puts

[1_000, 100_000, 500_000].each do |slice_size|
  offset = (BINARY_BUF.bytesize - slice_size) / 2
  Benchmark.ips do |x|
    x.config(warmup: 2, time: 5)
    x.report("String[#{offset}, #{slice_size}]") { BINARY_BUF[offset, slice_size] }
    x.report("SV[#{offset}, #{slice_size}]")     { SV_BINARY[offset, slice_size] }
    x.compare!
  end
  puts
end

# ===========================================================================
# Binary: Read-only ops
# ===========================================================================
puts "=" * 70
puts "Binary: Read-only ops on pre-existing inner slice"
puts "=" * 70
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#include?")      { STR_BINARY_INNER.include?("NEEDLE".b) }
  x.report("StringView#include?")  { SV_BINARY_INNER.include?("NEEDLE".b) }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#bytesize")      { STR_BINARY_INNER.bytesize }
  x.report("StringView#bytesize")  { SV_BINARY_INNER.bytesize }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#length")      { STR_BINARY_INNER.length }
  x.report("StringView#length")  { SV_BINARY_INNER.length }
  x.compare!
end
puts

# ===========================================================================
# UTF-8: Character counting (length)
# ===========================================================================
puts "=" * 70
puts "UTF-8: Character counting on #{UTF8_BUF.bytesize / 1024}KB string"
puts "=" * 70
puts

# Force a fresh view each time to measure uncached length
Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#length (cached)")      { UTF8_BUF.length }
  x.report("StringView#length (cached)")  { SV_UTF8.length }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#length (fresh)") do
    s = UTF8_BUF.dup.freeze
    s.length
  end
  x.report("StringView#length (fresh)") do
    sv = StringView.new(UTF8_BUF)
    sv.length
  end
  x.compare!
end
puts

# ===========================================================================
# UTF-8: Character-indexed slicing
# ===========================================================================
puts "=" * 70
puts "UTF-8: Character-indexed inner slicing (#{utf8_chars} chars)"
puts "=" * 70
puts

# Prime the stride index
SV_UTF8[1, 1]

[100, 1_000, 10_000].each do |char_offset|
  Benchmark.ips do |x|
    x.config(warmup: 2, time: 5)
    x.report("String[#{char_offset}, 100]") { UTF8_BUF[char_offset, 100] }
    x.report("SV[#{char_offset}, 100]")     { SV_UTF8[char_offset, 100] }
    x.compare!
  end
  puts
end

# ===========================================================================
# UTF-8: Read-only ops on pre-existing inner slice
# ===========================================================================
puts "=" * 70
puts "UTF-8: Read-only ops on pre-existing inner slice"
puts "=" * 70
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#include?")      { STR_UTF8_INNER.include?("café") }
  x.report("StringView#include?")  { SV_UTF8_INNER.include?("café") }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#start_with?")      { STR_UTF8_INNER.start_with?("日本語") }
  x.report("StringView#start_with?")  { SV_UTF8_INNER.start_with?("日本語") }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#bytesize")      { STR_UTF8_INNER.bytesize }
  x.report("StringView#bytesize")  { SV_UTF8_INNER.bytesize }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#length (cached)")      { STR_UTF8_INNER.length }
  x.report("StringView#length (cached)")  { SV_UTF8_INNER.length }
  x.compare!
end
puts

# ===========================================================================
# UTF-8: Combined slice + operate
# ===========================================================================
puts "=" * 70
puts "UTF-8: Combined inner-slice + operate"
puts "=" * 70
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String: slice+include?") { UTF8_BUF[utf8_chars / 4, utf8_chars / 2].include?("café") }
  x.report("SV: slice+include?")     { SV_UTF8[utf8_chars / 4, utf8_chars / 2].include?("café") }
  x.compare!
end
puts

# ===========================================================================
# Multi-encoding: 50 inner slices
# ===========================================================================
puts "=" * 70
puts "50 inner slices from each encoding"
puts "=" * 70
puts

ASCII_OFFSETS  = Array.new(50) { |i| [i * 10_000 + 100_000, 5_000] }
BINARY_OFFSETS = Array.new(50) { |i| [i * 10_000 + 100_000, 5_000] }

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String ASCII 50 slices")  { ASCII_OFFSETS.each { |off, len| ASCII_BUF[off, len] } }
  x.report("SV ASCII 50 slices")      { ASCII_OFFSETS.each { |off, len| SV_ASCII[off, len] } }
  x.compare!
end
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String Binary 50 slices") { BINARY_OFFSETS.each { |off, len| BINARY_BUF[off, len] } }
  x.report("SV Binary 50 slices")     { BINARY_OFFSETS.each { |off, len| SV_BINARY[off, len] } }
  x.compare!
end
puts

# ===========================================================================
# Memory comparison across encodings
# ===========================================================================
puts "=" * 70
puts "Memory: 1,000 inner slices of 10KB each"
puts "=" * 70

n = 1_000

[
  ["ASCII", ASCII_BUF, SV_ASCII],
  ["Binary", BINARY_BUF, SV_BINARY],
].each do |label, str, sv|
  slices_str = []
  slices_sv  = []

  GC.disable
  n.times { |i| slices_str << str[i * 500 + 100_000, 10_000] }
  n.times { |i| slices_sv  << sv[i * 500 + 100_000, 10_000] }
  GC.enable

  str_mem = slices_str.sum { |s| ObjectSpace.memsize_of(s) }
  sv_mem  = slices_sv.sum  { |s| ObjectSpace.memsize_of(s) }

  puts "  #{label}:"
  puts "    String:     #{str_mem} bytes"
  puts "    StringView: #{sv_mem} bytes"
  puts "    Ratio: String uses #{format("%.1f", str_mem.to_f / sv_mem)}x more memory"
  puts
end
