# frozen_string_literal: true

require "test_helper"
require_relative "sexp_parser"

#
# Tests for StringView::SexpParser — a zero-allocation S-expression parser
# built on StringView::Strict.
#
# These tests exercise almost every zero-copy method on StringView::Strict:
#
#   getbyte, byteslice, byteindex, index, chr, strip, lstrip, rstrip,
#   chomp, chop, delete_prefix, delete_suffix, include?, start_with?,
#   end_with?, empty?, ord, valid_encoding?, to_i, to_f, bytesize,
#   length, ==, eql?, hash, materialize
#
# The parser itself never calls .to_s — only .materialize in tests to
# verify correctness. During actual parsing, all token values that are
# symbol references remain as StringView::Strict objects.
#
class TestSexpParser < Minitest::Test
  T = StringView::SexpParser::Token

  # Helper: materialize token values for assertion (since symbol values
  # are StringView::Strict instances)
  def materialize(node)
    case node
    when Array
      if node.length == 2 && node[0] == :quote
        [:quote, materialize(node[1])]
      else
        node.map { |n| materialize(n) }
      end
    when T
      value = node.value
      if value.is_a?(StringView::Strict)
        T.new(type: node.type, value: value.materialize, byte_offset: node.byte_offset, byte_length: node.byte_length)
      else
        node
      end
    else
      node
    end
  end

  # =========================================================================
  # Lexer — tokenization
  # =========================================================================

  # -------------------------------------------------------------------------
  # Basic token types
  # -------------------------------------------------------------------------

  def test_lex_integer
    tokens = StringView::SexpParser.tokenize("42")
    assert_equal(1, tokens.length)
    assert_equal(:integer, tokens[0].type)
    assert_equal(42, tokens[0].value)
  end

  def test_lex_negative_integer
    tokens = StringView::SexpParser.tokenize("-17")
    assert_equal(1, tokens.length)
    assert_equal(:integer, tokens[0].type)
    assert_equal(-17, tokens[0].value)
  end

  def test_lex_positive_integer
    tokens = StringView::SexpParser.tokenize("+99")
    assert_equal(1, tokens.length)
    assert_equal(:integer, tokens[0].type)
    assert_equal(99, tokens[0].value)
  end

  def test_lex_zero
    tokens = StringView::SexpParser.tokenize("0")
    assert_equal(:integer, tokens[0].type)
    assert_equal(0, tokens[0].value)
  end

  def test_lex_float
    tokens = StringView::SexpParser.tokenize("3.14")
    assert_equal(1, tokens.length)
    assert_equal(:float, tokens[0].type)
    assert_in_delta(3.14, tokens[0].value)
  end

  def test_lex_negative_float
    tokens = StringView::SexpParser.tokenize("-2.718")
    assert_equal(:float, tokens[0].type)
    assert_in_delta(-2.718, tokens[0].value)
  end

  def test_lex_float_leading_zero
    tokens = StringView::SexpParser.tokenize("0.001")
    assert_equal(:float, tokens[0].type)
    assert_in_delta(0.001, tokens[0].value)
  end

  def test_lex_string
    tokens = StringView::SexpParser.tokenize('"hello world"')
    assert_equal(1, tokens.length)
    assert_equal(:string, tokens[0].type)
    # The value is a StringView::Strict (inner content without quotes)
    assert_instance_of(StringView::Strict, tokens[0].value)
    assert_equal("hello world", tokens[0].value.materialize)
  end

  def test_lex_empty_string
    tokens = StringView::SexpParser.tokenize('""')
    assert_equal(:string, tokens[0].type)
    assert_predicate(tokens[0].value, :empty?)
  end

  def test_lex_string_with_escape
    tokens = StringView::SexpParser.tokenize('"hello\"world"')
    assert_equal(:string, tokens[0].type)
    # The lexer preserves the escape sequence as-is (no unescaping)
    assert_equal('hello\"world', tokens[0].value.materialize)
  end

  def test_lex_string_with_newline_escape
    tokens = StringView::SexpParser.tokenize('"line1\\nline2"')
    assert_equal(:string, tokens[0].type)
    assert_equal('line1\\nline2', tokens[0].value.materialize)
  end

  def test_lex_symbol
    tokens = StringView::SexpParser.tokenize("define")
    assert_equal(1, tokens.length)
    assert_equal(:symbol, tokens[0].type)
    assert_instance_of(StringView::Strict, tokens[0].value)
    assert_equal("define", tokens[0].value.materialize)
  end

  def test_lex_symbol_with_special_chars
    tokens = StringView::SexpParser.tokenize("string->int")
    assert_equal(:symbol, tokens[0].type)
    assert_equal("string->int", tokens[0].value.materialize)
  end

  def test_lex_symbol_with_question_mark
    tokens = StringView::SexpParser.tokenize("null?")
    assert_equal(:symbol, tokens[0].type)
    assert_equal("null?", tokens[0].value.materialize)
  end

  def test_lex_symbol_with_exclamation
    tokens = StringView::SexpParser.tokenize("set!")
    assert_equal(:symbol, tokens[0].type)
    assert_equal("set!", tokens[0].value.materialize)
  end

  def test_lex_arithmetic_symbols
    ["+", "-", "*", "/", "<", ">", "<=", ">=", "="].each do |sym|
      tokens = StringView::SexpParser.tokenize(sym)
      assert_equal(:symbol, tokens[0].type, "#{sym} should be a symbol")
      assert_equal(sym, tokens[0].value.materialize)
    end
  end

  def test_lex_keyword
    tokens = StringView::SexpParser.tokenize(":name")
    assert_equal(1, tokens.length)
    assert_equal(:keyword, tokens[0].type)
    assert_instance_of(StringView::Strict, tokens[0].value)
    assert_equal("name", tokens[0].value.materialize) # ':' stripped
  end

  def test_lex_keyword_with_hyphen
    tokens = StringView::SexpParser.tokenize(":first-name")
    assert_equal(:keyword, tokens[0].type)
    assert_equal("first-name", tokens[0].value.materialize)
  end

  def test_lex_boolean_true
    tokens = StringView::SexpParser.tokenize("#t")
    assert_equal(1, tokens.length)
    assert_equal(:boolean, tokens[0].type)
    assert_equal(true, tokens[0].value)
  end

  def test_lex_boolean_false
    tokens = StringView::SexpParser.tokenize("#f")
    assert_equal(:boolean, tokens[0].type)
    assert_equal(false, tokens[0].value)
  end

  def test_lex_nil
    tokens = StringView::SexpParser.tokenize("nil")
    assert_equal(1, tokens.length)
    assert_equal(:nil, tokens[0].type)
    assert_nil(tokens[0].value)
  end

  def test_lex_lparen
    tokens = StringView::SexpParser.tokenize("(")
    assert_equal(:lparen, tokens[0].type)
  end

  def test_lex_rparen
    tokens = StringView::SexpParser.tokenize(")")
    assert_equal(:rparen, tokens[0].type)
  end

  def test_lex_quote
    tokens = StringView::SexpParser.tokenize("'x")
    assert_equal(2, tokens.length)
    assert_equal(:quote, tokens[0].type)
    assert_equal(:symbol, tokens[1].type)
  end

  # -------------------------------------------------------------------------
  # Whitespace handling
  # -------------------------------------------------------------------------

  def test_lex_skips_spaces
    tokens = StringView::SexpParser.tokenize("  42  ")
    assert_equal(1, tokens.length)
    assert_equal(42, tokens[0].value)
  end

  def test_lex_skips_tabs
    tokens = StringView::SexpParser.tokenize("\t42\t")
    assert_equal(1, tokens.length)
    assert_equal(42, tokens[0].value)
  end

  def test_lex_skips_newlines
    tokens = StringView::SexpParser.tokenize("\n42\n")
    assert_equal(1, tokens.length)
    assert_equal(42, tokens[0].value)
  end

  def test_lex_skips_carriage_returns
    tokens = StringView::SexpParser.tokenize("\r\n42\r\n")
    assert_equal(1, tokens.length)
    assert_equal(42, tokens[0].value)
  end

  def test_lex_mixed_whitespace
    tokens = StringView::SexpParser.tokenize(" \t\n\r 42 \t\n\r ")
    assert_equal(1, tokens.length)
  end

  # -------------------------------------------------------------------------
  # Comments
  # -------------------------------------------------------------------------

  def test_lex_comment_only
    tokens = StringView::SexpParser.tokenize("; this is a comment")
    assert_empty(tokens)
  end

  def test_lex_comment_after_token
    tokens = StringView::SexpParser.tokenize("42 ; the answer")
    assert_equal(1, tokens.length)
    assert_equal(42, tokens[0].value)
  end

  def test_lex_comment_between_lines
    tokens = StringView::SexpParser.tokenize("42\n; skip this\n99")
    assert_equal(2, tokens.length)
    assert_equal(42, tokens[0].value)
    assert_equal(99, tokens[1].value)
  end

  def test_lex_multiple_comment_lines
    source = <<~SEXP
      ; Comment 1
      ; Comment 2
      42
      ; Comment 3
    SEXP
    tokens = StringView::SexpParser.tokenize(source)
    assert_equal(1, tokens.length)
    assert_equal(42, tokens[0].value)
  end

  # -------------------------------------------------------------------------
  # Token byte offsets
  # -------------------------------------------------------------------------

  def test_token_byte_offsets
    tokens = StringView::SexpParser.tokenize("(+ 1 2)")
    assert_equal(0, tokens[0].byte_offset) # (
    assert_equal(1, tokens[1].byte_offset) # +
    assert_equal(3, tokens[2].byte_offset) # 1
    assert_equal(5, tokens[3].byte_offset) # 2
    assert_equal(6, tokens[4].byte_offset) # )
  end

  def test_token_byte_lengths
    tokens = StringView::SexpParser.tokenize('(define "hello" 42)')
    lparen = tokens[0]
    assert_equal(1, lparen.byte_length)
    define = tokens[1]
    assert_equal(6, define.byte_length)
    hello = tokens[2]
    assert_equal(7, hello.byte_length) # includes quotes
    num = tokens[3]
    assert_equal(2, num.byte_length)
  end

  # -------------------------------------------------------------------------
  # Multi-token sequences
  # -------------------------------------------------------------------------

  def test_lex_simple_list
    tokens = StringView::SexpParser.tokenize("(+ 1 2)")
    types = tokens.map(&:type)
    assert_equal([:lparen, :symbol, :integer, :integer, :rparen], types)
  end

  def test_lex_nested_lists
    tokens = StringView::SexpParser.tokenize("(* (+ 1 2) 3)")
    types = tokens.map(&:type)
    assert_equal([:lparen, :symbol, :lparen, :symbol, :integer, :integer, :rparen, :integer, :rparen], types)
  end

  def test_lex_define_function
    # (define (square x) (* x x))
    # ( define ( square x ) ( * x x ) ) = 12 tokens
    tokens = StringView::SexpParser.tokenize("(define (square x) (* x x))")
    assert_equal(12, tokens.length)
    assert_equal(:lparen, tokens[0].type)
    assert_equal("define", tokens[1].value.materialize)
    assert_equal("square", tokens[3].value.materialize)
    assert_equal("x", tokens[4].value.materialize)
  end

  def test_lex_empty_input
    tokens = StringView::SexpParser.tokenize("")
    assert_empty(tokens)
  end

  def test_lex_only_whitespace
    tokens = StringView::SexpParser.tokenize("   \n\t  ")
    assert_empty(tokens)
  end

  def test_lex_empty_list
    tokens = StringView::SexpParser.tokenize("()")
    assert_equal(2, tokens.length)
    assert_equal(:lparen, tokens[0].type)
    assert_equal(:rparen, tokens[1].type)
  end

  # -------------------------------------------------------------------------
  # Lexer accepts StringView::Strict directly
  # -------------------------------------------------------------------------

  def test_lex_from_strict
    sv = StringView::Strict.new("(+ 1 2)")
    tokens = StringView::SexpParser.tokenize(sv)
    assert_equal(5, tokens.length)
  end

  def test_lex_from_string_view
    sv = StringView.new("(+ 1 2)")
    # This should work — the lexer wraps non-Strict input
    tokens = StringView::SexpParser::Lexer.new(sv.to_s).tokenize
    assert_equal(5, tokens.length)
  end

  # =========================================================================
  # Parser — AST construction
  # =========================================================================

  # -------------------------------------------------------------------------
  # Atoms
  # -------------------------------------------------------------------------

  def test_parse_integer
    node = StringView::SexpParser.parse("42")
    assert_instance_of(T, node)
    assert_equal(:integer, node.type)
    assert_equal(42, node.value)
  end

  def test_parse_float
    node = StringView::SexpParser.parse("3.14")
    assert_equal(:float, node.type)
    assert_in_delta(3.14, node.value)
  end

  def test_parse_string
    node = StringView::SexpParser.parse('"hello"')
    assert_equal(:string, node.type)
    assert_equal("hello", node.value.materialize)
  end

  def test_parse_symbol
    node = StringView::SexpParser.parse("foo")
    assert_equal(:symbol, node.type)
    assert_equal("foo", node.value.materialize)
  end

  def test_parse_keyword
    node = StringView::SexpParser.parse(":name")
    assert_equal(:keyword, node.type)
    assert_equal("name", node.value.materialize)
  end

  def test_parse_boolean_true
    node = StringView::SexpParser.parse("#t")
    assert_equal(:boolean, node.type)
    assert_equal(true, node.value)
  end

  def test_parse_boolean_false
    node = StringView::SexpParser.parse("#f")
    assert_equal(:boolean, node.type)
    assert_equal(false, node.value)
  end

  def test_parse_nil
    node = StringView::SexpParser.parse("nil")
    assert_equal(:nil, node.type)
    assert_nil(node.value)
  end

  # -------------------------------------------------------------------------
  # Lists
  # -------------------------------------------------------------------------

  def test_parse_empty_list
    node = StringView::SexpParser.parse("()")
    assert_instance_of(Array, node)
    assert_empty(node)
  end

  def test_parse_simple_list
    node = StringView::SexpParser.parse("(+ 1 2)")
    assert_instance_of(Array, node)
    assert_equal(3, node.length)
    assert_equal(:symbol, node[0].type)
    assert_equal(1, node[1].value)
    assert_equal(2, node[2].value)
  end

  def test_parse_nested_list
    node = StringView::SexpParser.parse("(* (+ 1 2) 3)")
    assert_equal(3, node.length)
    inner = node[1]
    assert_instance_of(Array, inner)
    assert_equal(3, inner.length)
  end

  def test_parse_deeply_nested
    node = StringView::SexpParser.parse("(a (b (c (d))))")
    assert_instance_of(Array, node)
    level1 = node[1]
    assert_instance_of(Array, level1)
    level2 = level1[1]
    assert_instance_of(Array, level2)
    level3 = level2[1]
    assert_instance_of(Array, level3)
    assert_equal("d", level3[0].value.materialize)
  end

  def test_parse_multiple_nested
    node = StringView::SexpParser.parse("(list (+ 1 2) (* 3 4) (- 5 6))")
    assert_equal(4, node.length)
    assert_instance_of(Array, node[1])
    assert_instance_of(Array, node[2])
    assert_instance_of(Array, node[3])
  end

  # -------------------------------------------------------------------------
  # Quoted expressions
  # -------------------------------------------------------------------------

  def test_parse_quoted_symbol
    node = StringView::SexpParser.parse("'foo")
    assert_equal(:quote, node[0])
    assert_instance_of(T, node[1])
    assert_equal(:symbol, node[1].type)
  end

  def test_parse_quoted_list
    node = StringView::SexpParser.parse("'(1 2 3)")
    assert_equal(:quote, node[0])
    assert_instance_of(Array, node[1])
    assert_equal(3, node[1].length)
  end

  def test_parse_quoted_in_list
    node = StringView::SexpParser.parse("(list 'a 'b)")
    assert_equal(3, node.length)
    assert_equal(:quote, node[1][0])
    assert_equal(:quote, node[2][0])
  end

  # -------------------------------------------------------------------------
  # parse_all — multiple top-level expressions
  # -------------------------------------------------------------------------

  def test_parse_all_single
    nodes = StringView::SexpParser.parse_all("42")
    assert_equal(1, nodes.length)
  end

  def test_parse_all_multiple
    nodes = StringView::SexpParser.parse_all("(define x 1) (define y 2)")
    assert_equal(2, nodes.length)
  end

  def test_parse_all_with_comments
    source = <<~SEXP
      ; First definition
      (define x 1)
      ; Second definition
      (define y 2)
    SEXP
    nodes = StringView::SexpParser.parse_all(source)
    assert_equal(2, nodes.length)
  end

  # -------------------------------------------------------------------------
  # Error handling
  # -------------------------------------------------------------------------

  def test_parse_unexpected_rparen
    assert_raises(RuntimeError) { StringView::SexpParser.parse(")") }
  end

  def test_parse_unterminated_list
    assert_raises(RuntimeError) { StringView::SexpParser.parse("(+ 1 2") }
  end

  # =========================================================================
  # Real-world-ish scenarios — full programs
  # =========================================================================

  FACTORIAL = <<~SEXP
    (define (factorial n)
      (if (<= n 1)
        1
        (* n (factorial (- n 1)))))
  SEXP

  def test_parse_factorial
    node = StringView::SexpParser.parse(FACTORIAL)
    assert_instance_of(Array, node)
    # (define (factorial n) ...)
    assert_equal("define", node[0].value.materialize)
    sig = node[1] # (factorial n)
    assert_equal("factorial", sig[0].value.materialize)
    assert_equal("n", sig[1].value.materialize)
  end

  FIBONACCI = <<~SEXP
    (define (fib n)
      ; Base cases
      (cond
        ((= n 0) 0)
        ((= n 1) 1)
        (#t (+ (fib (- n 1))
               (fib (- n 2))))))
  SEXP

  def test_parse_fibonacci
    node = StringView::SexpParser.parse(FIBONACCI)
    assert_equal("define", node[0].value.materialize)
    sig = node[1]
    assert_equal("fib", sig[0].value.materialize)
  end

  MAP_IMPL = <<~SEXP
    (define (map f lst)
      (if (null? lst)
        '()
        (cons (f (car lst))
              (map f (cdr lst)))))
  SEXP

  def test_parse_map
    node = StringView::SexpParser.parse(MAP_IMPL)
    assert_equal("define", node[0].value.materialize)
    sig = node[1]
    assert_equal("map", sig[0].value.materialize)
    assert_equal("f", sig[1].value.materialize)
    assert_equal("lst", sig[2].value.materialize)
  end

  MULTI_DEFINE = <<~SEXP
    ; Arithmetic helpers
    (define (square x) (* x x))

    ; A generic map implementation
    (define (map f lst)
      (if (null? lst)
        '()
        (cons (f (car lst))
              (map f (cdr lst)))))

    ; Apply square to a list
    (define result (map square '(1 2 3 4 5)))
  SEXP

  def test_parse_multi_define
    nodes = StringView::SexpParser.parse_all(MULTI_DEFINE)
    assert_equal(3, nodes.length)
    assert_equal("square", nodes[0][1][0].value.materialize)
    assert_equal("map", nodes[1][1][0].value.materialize)
    assert_equal("result", nodes[2][1].value.materialize)
  end

  LET_BINDING = <<~SEXP
    (let ((x 10)
          (y 20)
          (name "Alice"))
      (list :x x :y y :name name))
  SEXP

  def test_parse_let_binding
    node = StringView::SexpParser.parse(LET_BINDING)
    assert_equal("let", node[0].value.materialize)
    bindings = node[1]
    assert_equal(3, bindings.length)
    # First binding: (x 10)
    assert_equal("x", bindings[0][0].value.materialize)
    assert_equal(10, bindings[0][1].value)
    # Third binding: (name "Alice")
    assert_equal("name", bindings[2][0].value.materialize)
    assert_equal(:string, bindings[2][1].type)
    assert_equal("Alice", bindings[2][1].value.materialize)
    # Body
    body = node[2]
    assert_equal("list", body[0].value.materialize)
    assert_equal(:keyword, body[1].type) # :x
  end

  # =========================================================================
  # Exercises specific StringView::Strict zero-copy methods
  # =========================================================================

  # -------------------------------------------------------------------------
  # strip / lstrip / rstrip — used for whitespace-padded inputs
  # -------------------------------------------------------------------------

  def test_strip_on_padded_input
    # The lexer internally uses getbyte to skip whitespace, but let's verify
    # strip works on the source view itself
    sv = StringView::Strict.new("  (+ 1 2)  ")
    stripped = sv.strip
    assert_instance_of(StringView::Strict, stripped)
    assert_equal("(+ 1 2)", stripped.materialize)
    # Parse the stripped view
    node = StringView::SexpParser.parse(stripped)
    assert_instance_of(Array, node)
  end

  def test_lstrip_source_before_parse
    sv = StringView::Strict.new("\n\n  (define x 42)")
    node = StringView::SexpParser.parse(sv.lstrip)
    assert_equal("define", node[0].value.materialize)
  end

  def test_rstrip_source_before_parse
    sv = StringView::Strict.new("(define x 42)   \n\n")
    node = StringView::SexpParser.parse(sv.rstrip)
    assert_equal(42, node[2].value)
  end

  # -------------------------------------------------------------------------
  # chomp / chop — stripping trailing newlines/chars
  # -------------------------------------------------------------------------

  def test_chomp_before_parse
    sv = StringView::Strict.new("(+ 1 2)\n")
    node = StringView::SexpParser.parse(sv.chomp)
    assert_equal(3, node.length)
  end

  def test_chomp_crlf
    sv = StringView::Strict.new("42\r\n")
    chomped = sv.chomp
    node = StringView::SexpParser.parse(chomped)
    assert_equal(42, node.value)
  end

  def test_chop_removes_last_char
    sv = StringView::Strict.new("42X")
    chopped = sv.chop # removes 'X'
    assert_equal("42", chopped.materialize)
  end

  # -------------------------------------------------------------------------
  # delete_prefix / delete_suffix — stripping known wrappers
  # -------------------------------------------------------------------------

  def test_delete_prefix_shebang
    sv = StringView::Strict.new("#!scheme\n(+ 1 2)")
    trimmed = sv.delete_prefix("#!scheme\n")
    node = StringView::SexpParser.parse(trimmed)
    assert_instance_of(Array, node)
  end

  def test_delete_suffix_trailing_junk
    sv = StringView::Strict.new("(+ 1 2)\x00\x00")
    trimmed = sv.delete_suffix("\x00\x00")
    node = StringView::SexpParser.parse(trimmed)
    assert_instance_of(Array, node)
  end

  def test_delete_prefix_no_match
    sv = StringView::Strict.new("(+ 1 2)")
    same = sv.delete_prefix("nope")
    assert_equal(sv.bytesize, same.bytesize)
  end

  def test_delete_suffix_no_match
    sv = StringView::Strict.new("(+ 1 2)")
    same = sv.delete_suffix("nope")
    assert_equal(sv.bytesize, same.bytesize)
  end

  # -------------------------------------------------------------------------
  # chr — first character extraction
  # -------------------------------------------------------------------------

  def test_chr_identifies_expression_type
    lparen = StringView::Strict.new("(+ 1 2)").chr
    assert_equal("(", lparen.materialize)

    quote = StringView::Strict.new("'foo").chr
    assert_equal("'", quote.materialize)

    hash = StringView::Strict.new("#t").chr
    assert_equal("#", hash.materialize)
  end

  # -------------------------------------------------------------------------
  # ord — dispatch on first character code
  # -------------------------------------------------------------------------

  def test_ord_for_dispatch
    assert_equal(40, StringView::Strict.new("(").ord)  # '('
    assert_equal(41, StringView::Strict.new(")").ord)  # ')'
    assert_equal(39, StringView::Strict.new("'").ord)  # "'"
    assert_equal(34, StringView::Strict.new('"').ord) # '"'
    assert_equal(59, StringView::Strict.new(";").ord) # ';'
  end

  # -------------------------------------------------------------------------
  # index / byteindex — finding delimiters
  # -------------------------------------------------------------------------

  def test_index_finds_close_paren
    sv = StringView::Strict.new("(+ 1 2)")
    assert_equal(6, sv.index(")"))
  end

  def test_index_finds_space
    sv = StringView::Strict.new("define x")
    assert_equal(6, sv.index(" "))
  end

  def test_index_with_offset
    sv = StringView::Strict.new("(a (b c))")
    # Find second '(' starting from position 1
    assert_equal(3, sv.index("(", 1))
  end

  def test_index_not_found
    sv = StringView::Strict.new("hello")
    assert_nil(sv.index("z"))
  end

  def test_byteindex_finds_newline
    sv = StringView::Strict.new("line1\nline2")
    assert_equal(5, sv.byteindex("\n"))
  end

  # -------------------------------------------------------------------------
  # include? — substring presence
  # -------------------------------------------------------------------------

  def test_include_finds_keyword
    sv = StringView::Strict.new("(define x 42)")
    assert(sv.include?("define"))
    assert(sv.include?("42"))
    refute(sv.include?("lambda"))
  end

  # -------------------------------------------------------------------------
  # start_with? / end_with?
  # -------------------------------------------------------------------------

  def test_start_with_list
    sv = StringView::Strict.new("(+ 1 2)")
    assert(sv.start_with?("("))
    refute(sv.start_with?(")"))
  end

  def test_end_with_list
    sv = StringView::Strict.new("(+ 1 2)")
    assert(sv.end_with?(")"))
    refute(sv.end_with?("("))
  end

  # -------------------------------------------------------------------------
  # getbyte — byte-level inspection
  # -------------------------------------------------------------------------

  def test_getbyte_parens
    sv = StringView::Strict.new("()")
    assert_equal(40, sv.getbyte(0))  # '('
    assert_equal(41, sv.getbyte(1))  # ')'
  end

  def test_getbyte_negative_index
    sv = StringView::Strict.new("abc")
    assert_equal(99, sv.getbyte(-1)) # 'c'
  end

  def test_getbyte_out_of_bounds
    sv = StringView::Strict.new("abc")
    assert_nil(sv.getbyte(3))
  end

  # -------------------------------------------------------------------------
  # empty? — end of input
  # -------------------------------------------------------------------------

  def test_empty_on_consumed_input
    sv = StringView::Strict.new("")
    assert_predicate(sv, :empty?)
    tokens = StringView::SexpParser.tokenize(sv)
    assert_empty(tokens)
  end

  def test_not_empty
    sv = StringView::Strict.new("x")
    refute_predicate(sv, :empty?)
  end

  # -------------------------------------------------------------------------
  # valid_encoding? — UTF-8 validation
  # -------------------------------------------------------------------------

  def test_valid_encoding_ascii
    sv = StringView::Strict.new("(+ 1 2)")
    assert_predicate(sv, :valid_encoding?)
  end

  def test_valid_encoding_utf8
    sv = StringView::Strict.new('(print "日本語")')
    assert_predicate(sv, :valid_encoding?)
  end

  # -------------------------------------------------------------------------
  # to_i / to_f — numeric conversion on Strict
  # -------------------------------------------------------------------------

  def test_to_i_on_strict_view
    sv = StringView::Strict.new("42")
    assert_equal(42, sv.to_i)
  end

  def test_to_f_on_token_value
    sv = StringView::Strict.new("3.14")
    assert_in_delta(3.14, sv.to_f)
  end

  # -------------------------------------------------------------------------
  # bytesize / length — used for span calculations
  # -------------------------------------------------------------------------

  def test_bytesize_ascii
    sv = StringView::Strict.new("(+ 1 2)")
    assert_equal(7, sv.bytesize)
    assert_equal(7, sv.length)
  end

  def test_bytesize_vs_length_multibyte
    sv = StringView::Strict.new('"日本語"')
    assert_equal(11, sv.bytesize) # 1 + 9 + 1
    assert_equal(5, sv.length)    # " 日 本 語 "
  end

  # -------------------------------------------------------------------------
  # == / eql? / hash — comparison and identity
  # -------------------------------------------------------------------------

  def test_symbol_token_equality
    tokens1 = StringView::SexpParser.tokenize("define")
    tokens2 = StringView::SexpParser.tokenize("define")
    assert(tokens1[0].value.eql?(tokens2[0].value))
    assert_equal(tokens1[0].value, tokens2[0].value)
    assert_equal(tokens1[0].value.hash, tokens2[0].value.hash)
  end

  def test_symbol_token_as_hash_key
    lookup = {}
    StringView::SexpParser.tokenize("define lambda if").each { |t| lookup[t.value] = t.type }
    # Can look up by StringView::Strict
    assert_equal(:symbol, lookup[StringView::Strict.new("define")])
  end

  # =========================================================================
  # StringView::Strict guarantee — no accidental String allocation
  # =========================================================================

  def test_symbol_values_are_strict
    tokens = StringView::SexpParser.tokenize("(define (square x) (* x x))")
    symbol_tokens = tokens.select { |t| t.type == :symbol }
    symbol_tokens.each do |t|
      assert_instance_of(
        StringView::Strict,
        t.value,
        "Symbol '#{t.value.materialize}' should be StringView::Strict",
      )
    end
  end

  def test_string_values_are_strict
    tokens = StringView::SexpParser.tokenize('(print "hello" "world")')
    string_tokens = tokens.select { |t| t.type == :string }
    string_tokens.each do |t|
      assert_instance_of(
        StringView::Strict,
        t.value,
        "String value should be StringView::Strict",
      )
    end
  end

  def test_keyword_values_are_strict
    tokens = StringView::SexpParser.tokenize("(hash :name :age :city)")
    kw_tokens = tokens.select { |t| t.type == :keyword }
    kw_tokens.each do |t|
      assert_instance_of(StringView::Strict, t.value)
    end
  end

  def test_to_s_on_strict_token_value_raises
    tokens = StringView::SexpParser.tokenize("define")
    assert_raises(StringView::WouldAllocate) { tokens[0].value.to_s }
  end

  def test_materialize_on_token_value_works
    tokens = StringView::SexpParser.tokenize("define")
    s = tokens[0].value.materialize
    assert_instance_of(String, s)
    assert_equal("define", s)
  end

  # =========================================================================
  # Chained zero-copy operations — preprocessing pipeline
  # =========================================================================

  def test_preprocess_strip_chomp_delete_prefix_then_parse
    raw = "  #!scheme\n(define x 42)\n  "
    sv = StringView::Strict.new(raw)
    # Pipeline: strip → chomp → delete_prefix (remove shebang line)
    cleaned = sv.strip.delete_prefix("#!scheme\n")
    assert_instance_of(StringView::Strict, cleaned)
    node = StringView::SexpParser.parse(cleaned)
    assert_equal("define", node[0].value.materialize)
    assert_equal(42, node[2].value)
  end

  def test_preprocess_lstrip_rstrip_chain
    raw = "\n\n   (lambda (x) x)   \n\n"
    sv = StringView::Strict.new(raw)
    cleaned = sv.lstrip.rstrip
    assert_instance_of(StringView::Strict, cleaned)
    assert(cleaned.start_with?("("))
    assert(cleaned.end_with?(")"))
    node = StringView::SexpParser.parse(cleaned)
    assert_equal("lambda", node[0].value.materialize)
  end

  # =========================================================================
  # Unicode / multibyte in S-expressions
  # =========================================================================

  def test_parse_unicode_string_literal
    node = StringView::SexpParser.parse('(print "日本語")')
    assert_equal("print", node[0].value.materialize)
    assert_equal(:string, node[1].type)
    assert_equal("日本語", node[1].value.materialize)
  end

  def test_parse_emoji_string
    node = StringView::SexpParser.parse('(emoji "🎉🎊🎈")')
    assert_equal("🎉🎊🎈", node[1].value.materialize)
  end

  def test_parse_mixed_ascii_unicode
    source = '(greet "Hello, 世界!" :lang "日本語")'
    node = StringView::SexpParser.parse(source)
    assert_equal("Hello, 世界!", node[1].value.materialize)
    assert_equal(:keyword, node[2].type)
    assert_equal("日本語", node[3].value.materialize)
  end

  # =========================================================================
  # Large input / stress tests
  # =========================================================================

  def test_parse_large_flat_list
    # 1000 integers in a flat list
    elements = (1..1000).map(&:to_s).join(" ")
    source = "(list #{elements})"
    node = StringView::SexpParser.parse(source)
    assert_equal(1001, node.length) # 'list' + 1000 integers
    assert_equal(1, node[1].value)
    assert_equal(1000, node[1000].value)
  end

  def test_parse_deeply_nested_100_levels
    source = "(" * 100 + "x" + ")" * 100
    node = StringView::SexpParser.parse(source)
    # Walk down 100 levels of single-element lists to reach the atom
    current = node
    100.times do |i|
      assert_instance_of(Array, current, "Level #{i} should be Array")
      assert_equal(1, current.length, "Level #{i} should have 1 element")
      current = current[0]
    end
    assert_instance_of(T, current)
    assert_equal("x", current.value.materialize)
  end

  def test_parse_many_string_literals
    parts = 500.times.map { |i| "\"string_#{i}\"" }.join(" ")
    source = "(list #{parts})"
    node = StringView::SexpParser.parse(source)
    assert_equal(501, node.length)
    node[1..].each_with_index do |t, i|
      assert_equal(:string, t.type)
      assert_equal("string_#{i}", t.value.materialize)
    end
  end

  def test_parse_mixed_types_large
    # Mix of all token types
    parts = []
    100.times do |i|
      parts << "(entry #{i} #{i}.#{i} \"name_#{i}\" :key_#{i} #{"#t" if i.even?}#{"#f" if i.odd?} nil)"
    end
    source = "(data #{parts.join("\n")})"
    nodes = StringView::SexpParser.parse(source)
    assert_equal(101, nodes.length) # 'data' + 100 entries
  end

  REALISTIC_PROGRAM = <<~SEXP
    ;; A realistic Scheme-like program demonstrating various token types

    (define *global-config*
      (hash-map
        :debug    #f
        :verbose  #t
        :timeout  30
        :pi       3.14159
        :greeting "Hello, World!"
        :name     nil))

    (define (process-request req)
      ;; Extract fields from the request
      (let ((method  (get req :method))
            (path    (get req :path))
            (body    (get req :body))
            (headers (get req :headers)))
        ;; Validate the request
        (if (null? method)
          (error "Missing HTTP method")
          (cond
            ((= method "GET")
              (handle-get path headers))
            ((= method "POST")
              (handle-post path headers body))
            ((= method "DELETE")
              (handle-delete path headers))
            (#t
              (error (string-append "Unknown method: " method)))))))

    (define (fibonacci n)
      ;; Compute fibonacci with memoization
      (let ((memo (make-hash-table)))
        (define (fib-inner k)
          (cond
            ((< k 2) k)
            ((hash-has-key? memo k)
              (hash-ref memo k))
            (#t
              (let ((result (+ (fib-inner (- k 1))
                               (fib-inner (- k 2)))))
                (hash-set! memo k result)
                result))))
        (fib-inner n)))

    (define (main args)
      (let ((n (string->number (car args))))
        (display (string-append
          "fib(" (number->string n) ") = "
          (number->string (fibonacci n))))
        (newline)))
  SEXP

  def test_parse_realistic_program
    nodes = StringView::SexpParser.parse_all(REALISTIC_PROGRAM)
    assert_equal(4, nodes.length)

    # First: (define *global-config* ...)
    assert_equal("define", nodes[0][0].value.materialize)
    assert_equal("*global-config*", nodes[0][1].value.materialize)

    # Second: (define (process-request req) ...)
    assert_equal("define", nodes[1][0].value.materialize)
    assert_equal("process-request", nodes[1][1][0].value.materialize)

    # Third: (define (fibonacci n) ...)
    assert_equal("define", nodes[2][0].value.materialize)
    assert_equal("fibonacci", nodes[2][1][0].value.materialize)

    # Fourth: (define (main args) ...)
    assert_equal("define", nodes[3][0].value.materialize)
    assert_equal("main", nodes[3][1][0].value.materialize)
  end

  def test_realistic_program_token_count
    tokens = StringView::SexpParser.tokenize(REALISTIC_PROGRAM)
    # This is a non-trivial program — should have many tokens
    assert_operator(tokens.length, :>, 100)
    # All symbol/keyword/string values should be Strict
    tokens.each do |t|
      if t.value.is_a?(StringView)
        assert_instance_of(
          StringView::Strict,
          t.value,
          "Token #{t.type}:#{t.value.inspect} should be Strict",
        )
      end
    end
  end

  def test_realistic_program_all_token_types_present
    # Add a quoted expression to ensure :quote is present
    source_with_quote = REALISTIC_PROGRAM + "\n(define data '(1 2 3))\n"
    tokens = StringView::SexpParser.tokenize(source_with_quote)
    types = tokens.map(&:type).uniq.sort
    assert_includes(types, :lparen)
    assert_includes(types, :rparen)
    assert_includes(types, :symbol)
    assert_includes(types, :keyword)
    assert_includes(types, :string)
    assert_includes(types, :integer)
    assert_includes(types, :float)
    assert_includes(types, :boolean)
    assert_includes(types, :nil)
    assert_includes(types, :quote)
  end

  # =========================================================================
  # Zero-allocation verification — the lexer should not allocate Strings
  # =========================================================================

  def test_lexer_allocates_fewer_objects_than_naive
    source = REALISTIC_PROGRAM

    # Warm both lexers
    5.times { StringView::SexpParser.tokenize(source) }

    # Naive lexer: allocates String substrings for every atom
    naive_allocs = measure_allocs { naive_lex(source) }

    # StringView lexer: uses Strict views (still allocates Token structs + views)
    sv_allocs = measure_allocs { StringView::SexpParser.tokenize(source) }

    # The StringView lexer should allocate fewer objects because:
    # - No intermediate String objects from slice/index/match
    # - Strict views point into the backing buffer without copying
    assert_operator(
      sv_allocs,
      :<,
      naive_allocs,
      "StringView lexer should allocate fewer objects than naive " \
        "(sv=#{sv_allocs}, naive=#{naive_allocs})",
    )
  end

  private

  def measure_allocs(n = 100, &block)
    GC.disable
    before = GC.stat(:total_allocated_objects)
    n.times(&block)
    after = GC.stat(:total_allocated_objects)
    GC.enable
    (after - before).to_f / n
  end

  # Minimal naive String-based lexer for allocation comparison
  def naive_lex(source)
    source = source.to_s
    tokens = []
    pos = 0
    while pos < source.bytesize
      pos += 1 while pos < source.bytesize && " \t\n\r".include?(source[pos])
      break if pos >= source.bytesize

      ch = source[pos]
      if ch == ";"
        nl = source.index("\n", pos)
        pos = nl ? nl + 1 : source.bytesize
      elsif ch == "(" || ch == ")" || ch == "'"
        tokens << [ch, pos]
        pos += 1
      elsif ch == '"'
        start = pos
        pos += 1
        pos += (source[pos] == "\\" ? 2 : 1) while pos < source.bytesize && source[pos] != '"'
        pos += 1
        tokens << [source[start...pos], start] # allocates substring
      else
        start = pos
        pos += 1 while pos < source.bytesize && !" \t\n\r()\"';".include?(source[pos])
        tokens << [source[start...pos], start] # allocates substring
      end
    end
    tokens
  end
end
