#!/bin/bash
set -euo pipefail

# Pre-check: compile
make clean >/dev/null 2>&1 || true
ruby ext/string_view/extconf.rb >/dev/null 2>&1
make >/dev/null 2>&1 || { echo "COMPILE FAILED"; exit 1; }
cp string_view.bundle lib/string_view/

# Pre-check: tests pass
ruby -Ilib -Itest test/test_string_view.rb >/dev/null 2>&1 || { echo "TESTS FAILED"; exit 1; }

# Run the benchmark
exec ruby --yjit -Ilib -e '
require "string_view"
require "benchmark"

# --- Setup ---
ASCII_STR = ("Hello world! " * 10_000).freeze
SV_ASCII = StringView.new(ASCII_STR)

UTF8_STR = ("日本語テスト🎉café " * 5_000).freeze
SV_UTF8 = StringView.new(UTF8_STR)

BINARY_STR = ("\x00\x01\x02\xFF\xFE\xFD".b * 20_000).freeze
SV_BINARY = StringView.new(BINARY_STR)

$stderr.puts "ASCII:  #{ASCII_STR.bytesize}B/#{ASCII_STR.length}ch  UTF8: #{UTF8_STR.bytesize}B/#{UTF8_STR.length}ch  Bin: #{BINARY_STR.bytesize}B/#{BINARY_STR.length}ch"

def bench(n)
  t = Benchmark.realtime { n.times { yield } }
  (n / t).round
end

def report(name, sv_ips, str_ips)
  ratio = sv_ips.to_f / str_ips
  puts "METRIC sv_#{name}=#{sv_ips}"
  puts "METRIC str_#{name}=#{str_ips}"
  puts "METRIC #{name}_ratio=#{"%.2f" % ratio}"
end

scores = []

# --- length ---
sv = bench(500_000) { SV_ASCII.length }; st = bench(500_000) { ASCII_STR.length }
report("ascii_length", sv, st); scores << sv

sv = bench(5_000) { SV_UTF8.length }; st = bench(5_000) { UTF8_STR.length }
report("utf8_length", sv, st); scores << sv

sv = bench(500_000) { SV_BINARY.length }; st = bench(500_000) { BINARY_STR.length }
report("binary_length", sv, st); scores << sv

# --- slice [char_idx, char_len] ---
ac = ASCII_STR.length
sv = bench(200_000) { SV_ASCII[ac/4, ac/2] }; st = bench(200_000) { ASCII_STR[ac/4, ac/2] }
report("ascii_slice", sv, st); scores << sv

uc = UTF8_STR.length
sv = bench(5_000) { SV_UTF8[uc/4, uc/2] }; st = bench(5_000) { UTF8_STR[uc/4, uc/2] }
report("utf8_slice", sv, st); scores << sv

bc = BINARY_STR.length
sv = bench(200_000) { SV_BINARY[bc/4, bc/2] }; st = bench(200_000) { BINARY_STR[bc/4, bc/2] }
report("binary_slice", sv, st); scores << sv

# --- slice + include? (UTF-8) ---
sv = bench(5_000) { SV_UTF8[uc/4, uc/2].include?("café") }
st = bench(5_000) { UTF8_STR[uc/4, uc/2].include?("café") }
report("utf8_slice_include", sv, st); scores << sv

composite = (scores.inject(1.0) { |p, v| p * v } ** (1.0 / scores.size)).round
puts "METRIC composite=#{composite}"
'
