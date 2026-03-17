#!/bin/bash
set -euo pipefail

# Pre-check: compile
make clean >/dev/null 2>&1 || true
make >/dev/null 2>&1 || { echo "COMPILE FAILED"; exit 1; }
cp string_view.bundle lib/string_view/

# Pre-check: tests pass
ruby -Ilib -Itest test/test_string_view.rb >/dev/null 2>&1 || { echo "TESTS FAILED"; exit 1; }

# Run the benchmark — outputs METRIC lines
exec ruby --yjit -Ilib -e '
require "string_view"
require "benchmark"

SIZE = 1_000_000
LARGE = ("a" * (SIZE / 2) + "NEEDLE" + "b" * (SIZE / 2)).freeze
SV_LARGE = StringView.new(LARGE)

STR_INNER = LARGE[250_000, 500_000]
SV_INNER  = SV_LARGE[250_000, 500_000]

N_SLICE = 200_000
N_ACC   = 2_000_000
N_COMBO = 100_000
N_MULTI = 5_000

# --- Slice creation (inner 500KB) ---
t = Benchmark.realtime { N_SLICE.times { SV_LARGE[250_000, 500_000] } }
sv_slice_ips = (N_SLICE / t).round
t = Benchmark.realtime { N_SLICE.times { LARGE[250_000, 500_000] } }
str_slice_ips = (N_SLICE / t).round
puts "METRIC sv_slice_500k=#{sv_slice_ips}"
puts "METRIC str_slice_500k=#{str_slice_ips}"
puts "METRIC slice_500k_ratio=#{"%.2f" % (sv_slice_ips.to_f / str_slice_ips)}"

# --- bytesize on pre-existing slice ---
t = Benchmark.realtime { N_ACC.times { SV_INNER.bytesize } }
sv_bs_ips = (N_ACC / t).round
t = Benchmark.realtime { N_ACC.times { STR_INNER.bytesize } }
str_bs_ips = (N_ACC / t).round
puts "METRIC sv_bytesize=#{sv_bs_ips}"
puts "METRIC str_bytesize=#{str_bs_ips}"
puts "METRIC bytesize_ratio=#{"%.2f" % (sv_bs_ips.to_f / str_bs_ips)}"

# --- getbyte on pre-existing slice ---
t = Benchmark.realtime { N_ACC.times { SV_INNER.getbyte(250_000) } }
sv_gb_ips = (N_ACC / t).round
t = Benchmark.realtime { N_ACC.times { STR_INNER.getbyte(250_000) } }
str_gb_ips = (N_ACC / t).round
puts "METRIC sv_getbyte=#{sv_gb_ips}"
puts "METRIC str_getbyte=#{str_gb_ips}"
puts "METRIC getbyte_ratio=#{"%.2f" % (sv_gb_ips.to_f / str_gb_ips)}"

# --- start_with? on pre-existing slice ---
t = Benchmark.realtime { N_ACC.times { SV_INNER.start_with?("xxxxx") } }
sv_sw_ips = (N_ACC / t).round
t = Benchmark.realtime { N_ACC.times { STR_INNER.start_with?("xxxxx") } }
str_sw_ips = (N_ACC / t).round
puts "METRIC sv_start_with=#{sv_sw_ips}"
puts "METRIC str_start_with=#{str_sw_ips}"
puts "METRIC start_with_ratio=#{"%.2f" % (sv_sw_ips.to_f / str_sw_ips)}"

# --- Combined: slice + start_with? ---
t = Benchmark.realtime { N_COMBO.times { SV_LARGE[250_000, 500_000].start_with?("aaa") } }
sv_combo_ips = (N_COMBO / t).round
t = Benchmark.realtime { N_COMBO.times { LARGE[250_000, 500_000].start_with?("aaa") } }
str_combo_ips = (N_COMBO / t).round
puts "METRIC sv_slice_start_with=#{sv_combo_ips}"
puts "METRIC str_slice_start_with=#{str_combo_ips}"
puts "METRIC slice_start_with_ratio=#{"%.2f" % (sv_combo_ips.to_f / str_combo_ips)}"

# --- 50 inner slices ---
offsets = Array.new(50) { |i| [i * 10_000 + 100_000, 5_000] }
t = Benchmark.realtime { N_MULTI.times { offsets.each { |off, len| SV_LARGE[off, len] } } }
sv_multi_ips = (N_MULTI / t).round
t = Benchmark.realtime { N_MULTI.times { offsets.each { |off, len| LARGE[off, len] } } }
str_multi_ips = (N_MULTI / t).round
puts "METRIC sv_50_slices=#{sv_multi_ips}"
puts "METRIC str_50_slices=#{str_multi_ips}"
puts "METRIC multi_slice_ratio=#{"%.2f" % (sv_multi_ips.to_f / str_multi_ips)}"

# --- Composite score: geometric mean of all SV i/s values ---
sv_scores = [sv_slice_ips, sv_bs_ips, sv_gb_ips, sv_sw_ips, sv_combo_ips, sv_multi_ips]
composite = (sv_scores.inject(1.0) { |prod, v| prod * v } ** (1.0 / sv_scores.size)).round
puts "METRIC composite=#{composite}"
'
