# frozen_string_literal: true

require "benchmark/ips"
require "objspace"
require_relative "../lib/string_view"

# ---------------------------------------------------------------------------
# Setup: large string simulating a real-world buffer
# ---------------------------------------------------------------------------
SIZE = 1_000_000
LARGE = ("a" * (SIZE / 2) + "NEEDLE" + "b" * (SIZE / 2)).freeze
SV_LARGE = StringView.new(LARGE)

# Pre-sliced inner regions (not tail slices — String must copy here)
STR_INNER = LARGE[250_000, 500_000]
SV_INNER  = SV_LARGE[250_000, 500_000]

puts "Ruby #{RUBY_VERSION}  •  string_view #{StringView::VERSION}"
puts "Backing: #{LARGE.bytesize} bytes"
puts
puts "String inner slice memsize:     #{ObjectSpace.memsize_of(STR_INNER)}"
puts "StringView inner slice memsize: #{ObjectSpace.memsize_of(SV_INNER)}"
puts "  (String copies #{STR_INNER.bytesize} bytes; StringView copies 0)"
puts

# ---------------------------------------------------------------------------
# 1. Inner slice creation — this is where String MUST copy bytes.
# ---------------------------------------------------------------------------
puts "=" * 60
puts "Inner slice creation (String copies bytes, StringView doesn't)"
puts "=" * 60
puts

[1_000, 10_000, 100_000, 500_000].each do |slice_size|
  offset = (SIZE - slice_size) / 2  # always an inner slice
  Benchmark.ips do |x|
    x.config(warmup: 2, time: 5)
    x.report("String[#{offset}, #{slice_size}]")     { LARGE[offset, slice_size] }
    x.report("SV[#{offset}, #{slice_size}]")          { SV_LARGE[offset, slice_size] }
    x.compare!
  end
  puts
end

# ---------------------------------------------------------------------------
# 2. Read-only ops on a pre-existing inner slice
# ---------------------------------------------------------------------------
puts "=" * 60
puts "Read-only ops on pre-existing 500KB inner slice"
puts "=" * 60
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#include?")      { STR_INNER.include?("NEEDLE") }
  x.report("StringView#include?")  { SV_INNER.include?("NEEDLE") }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#start_with?")      { STR_INNER.start_with?("xxxxx") }
  x.report("StringView#start_with?")  { SV_INNER.start_with?("xxxxx") }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#bytesize")      { STR_INNER.bytesize }
  x.report("StringView#bytesize")  { SV_INNER.bytesize }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#getbyte(250K)")      { STR_INNER.getbyte(250_000) }
  x.report("StringView#getbyte(250K)")  { SV_INNER.getbyte(250_000) }
  x.compare!
end

puts

# ---------------------------------------------------------------------------
# 3. Combined: inner slice + operate (the real-world pattern)
# ---------------------------------------------------------------------------
puts "=" * 60
puts "Combined: inner-slice then operate (the real win scenario)"
puts "=" * 60
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String: inner slice+include?") {
    LARGE[250_000, 500_000].include?("NEEDLE")
  }
  x.report("SV: inner slice+include?") {
    SV_LARGE[250_000, 500_000].include?("NEEDLE")
  }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String: inner slice+start_with?") {
    LARGE[250_000, 500_000].start_with?("aaa")
  }
  x.report("SV: inner slice+start_with?") {
    SV_LARGE[250_000, 500_000].start_with?("aaa")
  }
  x.compare!
end

puts

# ---------------------------------------------------------------------------
# 4. Many inner slices — simulates parsing fields from a large buffer
# ---------------------------------------------------------------------------
puts "=" * 60
puts "50 inner slices from a 1MB buffer"
puts "=" * 60
puts

OFFSETS = Array.new(50) { |i| [i * 10_000 + 100_000, 5_000] }

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String 50 inner slices") {
    OFFSETS.each { |off, len| LARGE[off, len] }
  }
  x.report("SV 50 inner slices") {
    OFFSETS.each { |off, len| SV_LARGE[off, len] }
  }
  x.compare!
end

puts

# ---------------------------------------------------------------------------
# 5. Allocation + memory comparison
# ---------------------------------------------------------------------------
puts "=" * 60
puts "Allocation & memory: 1,000 inner slices of 10KB each from 1MB"
puts "=" * 60

n = 1_000
slices_str = []
slices_sv  = []

GC.disable
before = GC.stat(:total_allocated_objects)
n.times { |i| slices_str << LARGE[i * 500 + 100_000, 10_000] }
after = GC.stat(:total_allocated_objects)
str_allocs = after - before

before = GC.stat(:total_allocated_objects)
n.times { |i| slices_sv << SV_LARGE[i * 500 + 100_000, 10_000] }
after = GC.stat(:total_allocated_objects)
sv_allocs = after - before
GC.enable

str_mem = slices_str.sum { |s| ObjectSpace.memsize_of(s) }
sv_mem  = slices_sv.sum  { |s| ObjectSpace.memsize_of(s) }

puts "  String:     #{str_allocs} allocs, #{str_mem} bytes total memsize"
puts "  StringView: #{sv_allocs} allocs, #{sv_mem} bytes total memsize"
puts "  Memory ratio: String uses #{str_mem.to_f / sv_mem}x more memory"
