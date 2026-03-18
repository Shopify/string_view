#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Benchmark: StringView::SexpParser vs a naive String-based S-expression lexer
#
# Compares allocation count and throughput of:
#   1. StringView::Strict-based lexer (zero intermediate String allocs)
#   2. Naive String-based lexer (allocates substrings via String#[] and String#slice)
#
# Usage:
#   bundle exec ruby --yjit bench/sexp_parser_bench.rb
#

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "string_view"
require_relative "../test/parsing/sexp_parser"

# ---------------------------------------------------------------------------
# Naive String-based lexer (for comparison)
# ---------------------------------------------------------------------------
module NaiveStringLexer
  Token = Struct.new(:type, :value, :offset, :length, keyword_init: true)

  DELIMITERS = /[\s()"';]/

  def self.tokenize(source)
    source = source.to_s
    tokens = []
    pos = 0

    while pos < source.bytesize
      # Skip whitespace
      while pos < source.bytesize && " \t\n\r".include?(source[pos])
        pos += 1
      end
      break if pos >= source.bytesize

      ch = source[pos]

      # Skip comments
      if ch == ";"
        nl = source.index("\n", pos)
        pos = nl ? nl + 1 : source.bytesize
        next
      end

      case ch
      when "("
        tokens << Token.new(type: :lparen, value: nil, offset: pos, length: 1)
        pos += 1
      when ")"
        tokens << Token.new(type: :rparen, value: nil, offset: pos, length: 1)
        pos += 1
      when "'"
        tokens << Token.new(type: :quote, value: nil, offset: pos, length: 1)
        pos += 1
      when '"'
        start = pos
        pos += 1
        while pos < source.bytesize
          if source[pos] == "\\"
            pos += 2
          elsif source[pos] == '"'
            pos += 1
            break
          else
            pos += 1
          end
        end
        inner = source[(start + 1)..(pos - 2)] # allocates!
        tokens << Token.new(type: :string, value: inner, offset: start, length: pos - start)
      when "#"
        if pos + 1 < source.bytesize
          nxt = source[pos + 1]
          if nxt == "t"
            tokens << Token.new(type: :boolean, value: true, offset: pos, length: 2)
            pos += 2
            next
          elsif nxt == "f"
            tokens << Token.new(type: :boolean, value: false, offset: pos, length: 2)
            pos += 2
            next
          end
        end
        start = pos
        pos += 1
        pos += 1 while pos < source.bytesize && !DELIMITERS.match?(source[pos])
        span = source[start...pos] # allocates!
        tokens << Token.new(type: :symbol, value: span, offset: start, length: pos - start)
      when ":"
        start = pos
        pos += 1
        pos += 1 while pos < source.bytesize && !DELIMITERS.match?(source[pos])
        name = source[(start + 1)...pos] # allocates!
        tokens << Token.new(type: :keyword, value: name, offset: start, length: pos - start)
      else
        start = pos
        pos += 1 while pos < source.bytesize && !DELIMITERS.match?(source[pos])
        span = source[start...pos] # allocates!

        if span == "nil"
          tokens << Token.new(type: :nil, value: nil, offset: start, length: pos - start)
        elsif span.match?(/\A[+-]?\d+\z/)
          tokens << Token.new(type: :integer, value: span.to_i, offset: start, length: pos - start)
        elsif span.match?(/\A[+-]?\d+\.\d+\z/)
          tokens << Token.new(type: :float, value: span.to_f, offset: start, length: pos - start)
        else
          tokens << Token.new(type: :symbol, value: span, offset: start, length: pos - start)
        end
      end
    end

    tokens
  end
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def measure_time(n)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  n.times(&block)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  t1 - t0
end

def measure_allocs
  GC.disable
  before = GC.stat(:total_allocated_objects)
  yield
  after = GC.stat(:total_allocated_objects)
  GC.enable
  after - before
end

# ---------------------------------------------------------------------------
# Test data — a realistic program, repeated to get a substantial buffer
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

# Scale up: repeat the program to make a ~100KB buffer
SCALE = 50
SOURCE = (PROGRAM * SCALE).freeze

puts "=" * 72
puts "StringView::SexpParser Benchmark"
puts "=" * 72
puts
puts "Source size: #{SOURCE.bytesize} bytes (#{SOURCE.lines.count} lines, #{SCALE}× repeated)"
puts "Ruby:        #{RUBY_DESCRIPTION}"
puts

# ---------------------------------------------------------------------------
# Correctness check
# ---------------------------------------------------------------------------
sv_tokens = StringView::SexpParser.tokenize(SOURCE)
naive_tokens = NaiveStringLexer.tokenize(SOURCE)
puts "Tokens (StringView): #{sv_tokens.length}"
puts "Tokens (Naive):      #{naive_tokens.length}"
raise "Token count mismatch!" unless sv_tokens.length == naive_tokens.length
puts "✓ Token counts match"
puts

# ---------------------------------------------------------------------------
# Allocation comparison
# ---------------------------------------------------------------------------
puts "-" * 72
puts "Allocation comparison (single run)"
puts "-" * 72

# Warm up
5.times { StringView::SexpParser.tokenize(SOURCE) }
5.times { NaiveStringLexer.tokenize(SOURCE) }

sv_allocs = measure_allocs { StringView::SexpParser.tokenize(SOURCE) }
naive_allocs = measure_allocs { NaiveStringLexer.tokenize(SOURCE) }

puts "StringView lexer:  #{sv_allocs} objects"
puts "Naive lexer:       #{naive_allocs} objects"
puts "Savings:           #{naive_allocs - sv_allocs} fewer objects (#{((1.0 - sv_allocs.to_f / naive_allocs) * 100).round(1)}%)"
puts

# ---------------------------------------------------------------------------
# Throughput benchmark — lexer
# ---------------------------------------------------------------------------
puts "-" * 72
puts "Throughput benchmark (lexer only)"
puts "-" * 72

n = 50
puts "Iterations: #{n}"
puts

# Warm
5.times { StringView::SexpParser.tokenize(SOURCE) }
5.times { NaiveStringLexer.tokenize(SOURCE) }

sv_time = measure_time(n) { StringView::SexpParser.tokenize(SOURCE) }
naive_time = measure_time(n) { NaiveStringLexer.tokenize(SOURCE) }

printf "  StringView lexer:  %7.3fs  (%5.1f ms/iter)\n", sv_time, sv_time / n * 1000
printf "  Naive String lexer:%7.3fs  (%5.1f ms/iter)\n", naive_time, naive_time / n * 1000
printf "  Speedup:           %.2fx\n", naive_time / sv_time
puts

# ---------------------------------------------------------------------------
# Full parse benchmark (lexer + AST construction)
# ---------------------------------------------------------------------------
puts "-" * 72
puts "Full parse benchmark (lex + parse)"
puts "-" * 72

n_parse = 20
5.times { StringView::SexpParser.parse_all(SOURCE) }
parse_time = measure_time(n_parse) { StringView::SexpParser.parse_all(SOURCE) }
printf "  StringView parse:  %7.3fs  (%5.1f ms/iter, %d iters)\n", parse_time, parse_time / n_parse * 1000, n_parse
puts

# ---------------------------------------------------------------------------
# Per-token throughput
# ---------------------------------------------------------------------------
puts "-" * 72
puts "Per-token throughput"
puts "-" * 72

tokens_per_run = sv_tokens.length
total_tokens = tokens_per_run * n
sv_tps = total_tokens / sv_time
naive_tps = total_tokens / naive_time

printf "  StringView: %5.2fM tokens/s  (%4.0fns/token)\n", sv_tps / 1e6, 1e9 / sv_tps
printf "  Naive:      %5.2fM tokens/s  (%4.0fns/token)\n", naive_tps / 1e6, 1e9 / naive_tps
printf "  Speedup:    %.2fx\n", sv_tps / naive_tps
puts
printf "  Throughput: %.1fMB/s (StringView)\n", (SOURCE.bytesize * n) / sv_time / 1e6
printf "              %.1fMB/s (Naive)\n", (SOURCE.bytesize * n) / naive_time / 1e6

puts
puts "=" * 72
