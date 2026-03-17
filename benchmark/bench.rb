# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/string_view"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
LARGE = ("x" * 10_000 + "NEEDLE" + "y" * 10_000).freeze
SV_LARGE = StringView.new(LARGE)

# Pre-sliced: the caller already has a region of interest.
# With String, you'd have to slice first (allocating) then operate.
# With StringView, you slice once (cheap struct) then operate for free.
STR_SLICE = LARGE[5_000, 10_000]
SV_SLICE  = SV_LARGE[5_000, 10_000]

puts "Ruby #{RUBY_VERSION}  •  string_view #{StringView::VERSION}"
puts "Backing size: #{LARGE.bytesize} bytes"
puts "Slice size:   #{STR_SLICE.bytesize} bytes"
puts

# ---------------------------------------------------------------------------
# 1. Read-only operations on a pre-existing slice (no new allocation).
#    This is where StringView should match or beat String.
# ---------------------------------------------------------------------------
puts "=" * 60
puts "Tier 1: Read-only ops on a pre-existing slice"
puts "=" * 60
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#bytesize")      { STR_SLICE.bytesize }
  x.report("StringView#bytesize")  { SV_SLICE.bytesize }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#include?")      { STR_SLICE.include?("NEEDLE") }
  x.report("StringView#include?")  { SV_SLICE.include?("NEEDLE") }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#start_with?")      { STR_SLICE.start_with?("NEEDLE") }
  x.report("StringView#start_with?")  { SV_SLICE.start_with?("NEEDLE") }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#getbyte")      { STR_SLICE.getbyte(500) }
  x.report("StringView#getbyte")  { SV_SLICE.getbyte(500) }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#==")      { STR_SLICE == STR_SLICE }
  x.report("StringView#==")  { SV_SLICE == SV_SLICE }
  x.compare!
end

puts

# ---------------------------------------------------------------------------
# 2. Slice creation — StringView vs String.
# ---------------------------------------------------------------------------
puts "=" * 60
puts "Tier 2: Slice creation"
puts "=" * 60
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String#[]")      { LARGE[5_000, 10_000] }
  x.report("StringView#[]")  { SV_LARGE[5_000, 10_000] }
  x.compare!
end

puts

# ---------------------------------------------------------------------------
# 3. Slice-then-operate: the combined cost (allocation + work).
#    This is the real-world pattern: parse a buffer, extract a region, query it.
# ---------------------------------------------------------------------------
puts "=" * 60
puts "Tier combined: slice + operate"
puts "=" * 60
puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String: slice+include?") {
    LARGE[5_000, 10_000].include?("NEEDLE")
  }
  x.report("SV: slice+include?") {
    SV_LARGE[5_000, 10_000].include?("NEEDLE")
  }
  x.compare!
end

puts

Benchmark.ips do |x|
  x.config(warmup: 2, time: 5)
  x.report("String: slice+start_with?") {
    LARGE[5_000, 10_000].start_with?("NEEDLE")
  }
  x.report("SV: slice+start_with?") {
    SV_LARGE[5_000, 10_000].start_with?("NEEDLE")
  }
  x.compare!
end

puts

# ---------------------------------------------------------------------------
# 4. Allocation comparison
# ---------------------------------------------------------------------------
puts "=" * 60
puts "Allocation comparison (10,000 slices from a 20KB string):"
puts "=" * 60

n = 10_000

GC.disable
before = GC.stat(:total_allocated_objects)
n.times { |i| LARGE[i % 10_000, 100] }
after = GC.stat(:total_allocated_objects)
puts "  String#[]:      #{after - before} allocations"

before = GC.stat(:total_allocated_objects)
n.times { |i| SV_LARGE[i % 10_000, 100] }
after = GC.stat(:total_allocated_objects)
puts "  StringView#[]:  #{after - before} allocations"
GC.enable
