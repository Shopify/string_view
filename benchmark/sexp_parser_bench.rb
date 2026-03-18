#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Benchmark: S-expression lexer across four StringView modes
#
# Compares allocation count and throughput of:
#   1. String             — plain Ruby substrings (baseline)
#   2. StringView         — one StringView alloc per slice
#   3. StringView::Strict — one Strict alloc per slice
#   4. StringView::Pool   — zero alloc per slice in steady state
#
# Two scenarios:
#   A) Cold — new Lexer each call (like parsing different inputs)
#   B) Hot  — same Lexer reused with reset! (like parsing messages in a loop)
#
# Pool only wins in scenario B, where pre-allocated views get reused.
#
# Usage:
#   bundle exec ruby --yjit bench/sexp_parser_bench.rb
#

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "string_view"
require_relative "../test/parsing/sexp_parser"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def measure_time(n, &block)
  GC.start
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  n.times(&block)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  t1 - t0
end

def measure_allocs(n = 1, &block)
  GC.start
  GC.disable
  before = GC.stat(:total_allocated_objects)
  n.times(&block)
  after = GC.stat(:total_allocated_objects)
  GC.enable
  (after - before).to_f / n
end

def fmt_num(n)
  n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end

# ---------------------------------------------------------------------------
# Test data
# ---------------------------------------------------------------------------
PROGRAM = <<~SEXP
  ;; A realistic Scheme-like program

  (define *config*
    (hash-map :debug #f :verbose #t :timeout 30 :pi 3.14159 :greeting "Hello, World!" :name nil))

  (define (process-request req)
    (let ((method  (get req :method))
          (path    (get req :path))
          (body    (get req :body))
          (headers (get req :headers)))
      (if (null? method)
        (error "Missing HTTP method")
        (cond
          ((= method "GET")    (handle-get path headers))
          ((= method "POST")   (handle-post path headers body))
          ((= method "DELETE") (handle-delete path headers))
          (#t (error (string-append "Unknown method: " method)))))))

  (define (fibonacci n)
    (let ((memo (make-hash-table)))
      (define (fib k)
        (cond
          ((< k 2) k)
          ((hash-has-key? memo k) (hash-ref memo k))
          (#t (let ((r (+ (fib (- k 1)) (fib (- k 2)))))
                (hash-set! memo k r) r))))
      (fib n)))

  (define (main args)
    (let ((n (string->number (car args))))
      (display (string-append "fib(" (number->string n) ") = " (number->string (fibonacci n))))
      (newline)))
SEXP

SCALE = 50
SOURCE = (PROGRAM * SCALE).freeze

HAS_POOL = defined?(StringView::Pool)
MODES = [:string, :string_view, :strict]
MODES << :pool if HAS_POOL

MODE_LABELS = {
  string: "String",
  string_view: "StringView",
  strict: "Strict",
  pool: "Pool",
}.freeze

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
puts
puts "=" * 72
puts "  S-expression Lexer Benchmark"
puts "=" * 72
puts
puts "  Source: #{fmt_num(SOURCE.bytesize)} bytes, #{fmt_num(SOURCE.lines.count)} lines (#{SCALE}× repeated)"
puts "  Ruby:   #{RUBY_DESCRIPTION}"
puts "  Modes:  #{MODES.map { |m| MODE_LABELS[m] }.join(", ")}"
puts

# Correctness
counts = MODES.map { |m| [m, StringView::SexpParser.tokenize(SOURCE, mode: m).length] }.to_h
token_count = counts.values.first
puts "  Tokens: #{fmt_num(token_count)}"
unless counts.values.uniq.length == 1
  abort "  !! Token count mismatch: #{counts}"
end
puts "  ✓ All modes produce identical token streams"
puts

# Warm all modes
MODES.each { |m| 5.times { StringView::SexpParser.tokenize(SOURCE, mode: m) } }

max_label = MODE_LABELS.values.map(&:length).max

# =====================================================================
# Scenario A: Cold — new Lexer per call
# =====================================================================
puts "=" * 72
puts "  Scenario A: Cold — new Lexer each call"
puts "  (like parsing different inputs each time)"
puts "=" * 72
puts

# --- Allocations ---
puts "  Allocations (single pass)"
alloc_a = {}
MODES.each do |m|
  alloc_a[m] = measure_allocs { StringView::SexpParser.tokenize(SOURCE, mode: m) }.round
end
base_a = alloc_a[:string]
MODES.each do |m|
  a = alloc_a[m]
  diff = a - base_a
  note = if diff == 0
    ""
  else
    diff > 0 ? "  (+#{fmt_num(diff)})" : "  (#{fmt_num(diff)})"
  end
  printf "    %-#{max_label}s  %8s objects%s\n", MODE_LABELS[m], fmt_num(a), note
end
puts

# --- Throughput ---
n = 50
puts "  Throughput (lex only, #{n} iterations)"
time_a = {}
MODES.each do |m|
  time_a[m] = measure_time(n) { StringView::SexpParser.tokenize(SOURCE, mode: m) }
end
str_t = time_a[:string]
MODES.each do |m|
  t = time_a[m]
  ms = t / n * 1000
  tps = token_count * n / t
  mbs = SOURCE.bytesize * n / t / 1e6
  printf "    %-#{max_label}s  %5.1f ms/iter  %5.1fM tok/s  %5.1f MB/s", MODE_LABELS[m], ms, tps / 1e6, mbs
  printf "  (%.2fx)", str_t / t if m != :string
  puts
end
puts

# =====================================================================
# Scenario B: Hot — reuse Lexer with tokenize (Pool calls reset!)
# =====================================================================
puts "=" * 72
puts "  Scenario B: Hot — same Lexer, repeated tokenize"
puts "  (like parsing messages in a server loop)"
puts "=" * 72
puts

# Build a reusable Lexer for each mode
lexers = {}
MODES.each do |m|
  lexers[m] = StringView::SexpParser::Lexer.new(SOURCE, mode: m)
end

# Warm: tokenize a few times (Pool grows to needed capacity)
MODES.each { |m| 10.times { lexers[m].tokenize } }

# --- Allocations per tokenize call (amortized over many calls) ---
puts "  Allocations per tokenize (amortized, #{n} calls)"
alloc_b = {}
MODES.each do |m|
  lexer = lexers[m]
  alloc_b[m] = measure_allocs(n) { lexer.tokenize }.round
end
base_b = alloc_b[:string]
MODES.each do |m|
  a = alloc_b[m]
  diff = a - base_b
  note = if diff == 0
    ""
  else
    diff > 0 ? "  (+#{fmt_num(diff)})" : "  (#{fmt_num(diff)})"
  end
  printf "    %-#{max_label}s  %8s objects%s\n", MODE_LABELS[m], fmt_num(a), note
end
puts

# --- Throughput ---
puts "  Throughput (lex only, #{n} iterations)"
time_b = {}
MODES.each do |m|
  lexer = lexers[m]
  time_b[m] = measure_time(n) { lexer.tokenize }
end
str_b = time_b[:string]
MODES.each do |m|
  t = time_b[m]
  ms = t / n * 1000
  tps = token_count * n / t
  mbs = SOURCE.bytesize * n / t / 1e6
  printf "    %-#{max_label}s  %5.1f ms/iter  %5.1fM tok/s  %5.1f MB/s", MODE_LABELS[m], ms, tps / 1e6, mbs
  printf "  (%.2fx)", str_b / t if m != :string
  puts
end
puts

# =====================================================================
# Summary
# =====================================================================
puts "=" * 72
puts "  Summary"
puts "=" * 72
puts
puts "  vs String baseline          Cold (new Lexer)    Hot (reuse Lexer)"
puts "  " + "-" * 68
MODES.each do |m|
  next if m == :string

  cold_alloc = ((1.0 - alloc_a[m].to_f / base_a) * 100)
  cold_speed = str_t / time_a[m]
  hot_alloc  = ((1.0 - alloc_b[m].to_f / base_b) * 100)
  hot_speed  = str_b / time_b[m]
  printf "  %-#{max_label}s              alloc %+5.1f%% %4.2fx   alloc %+5.1f%% %4.2fx\n",
    MODE_LABELS[m],
    -cold_alloc,
    cold_speed,
    -hot_alloc,
    hot_speed
end
puts
puts "=" * 72
puts
