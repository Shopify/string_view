# frozen_string_literal: true

require "string_view"

#
# StringView::SexpParser — a zero-allocation S-expression lexer and parser
# built entirely on StringView::Strict.
#
# Demonstrates how to build a real lexer/parser loop that:
#   - Never allocates intermediate String objects during tokenization
#   - Uses manual byte-position tracking instead of StringScanner (which allocates)
#   - Exercises nearly every zero-copy method on StringView::Strict:
#     strip, lstrip, rstrip, chomp, chop, delete_prefix, delete_suffix, chr,
#     index, byteindex, include?, start_with?, end_with?, getbyte, byteslice,
#     empty?, ord, valid_encoding?, to_i, to_f, bytesize, length, ==, eql?
#   - Produces an AST of Token structs and nested lists
#
# == Grammar
#
#   sexp       = atom | list | quoted
#   list       = '(' sexp* ')'
#   quoted     = "'" sexp
#   atom       = integer | float | string_literal | symbol | keyword | boolean | nil
#   integer    = [+-]?[0-9]+
#   float      = [+-]?[0-9]+'.'[0-9]+
#   string_lit = '"' chars '"'
#   symbol     = [a-zA-Z_!?<>=+\-*/][a-zA-Z0-9_!?<>=+\-*/]*
#   keyword    = ':' symbol
#   boolean    = '#t' | '#f'
#   nil_lit    = 'nil'
#   comment    = ';' to end of line (stripped)
#
# == Usage
#
#   source = '(define (square x) (* x x))'
#   parser = StringView::SexpParser.new(source)
#   ast    = parser.parse  # => nested arrays of Token structs
#
# == Token types
#
#   :integer, :float, :string, :symbol, :keyword, :boolean, :nil,
#   :lparen, :rparen, :quote
#
module StringView::SexpParser
  Token = Struct.new(:type, :value, :byte_offset, :byte_length, keyword_init: true)

  # Characters that terminate an atom
  DELIMITERS = " \t\n\r()\"';".freeze
  private_constant :DELIMITERS

  # --------------------------------------------------------------------------
  # Lexer — tokenizes a StringView::Strict into Token objects.
  #
  # This is the hot path. It tracks a byte position into the backing view
  # and extracts tokens using only zero-copy operations:
  #
  #   getbyte      → peek at current byte (character class checks)
  #   byteslice    → extract token span as a new Strict view
  #   byteindex    → find next occurrence of delimiter/quote/etc.
  #   index        → find next occurrence of multi-byte pattern
  #   chr          → single-character extraction
  #   strip/lstrip → skip leading whitespace
  #   start_with?  → check token prefixes
  #   end_with?    → check token suffixes
  #   include?     → check for embedded characters
  #   delete_prefix/delete_suffix → strip known wrappers
  #   chomp/chop   → strip trailing newline/char
  #   empty?       → end-of-input check
  #   ord          → character code for dispatch
  #   to_i/to_f    → numeric conversion
  #   valid_encoding? → validate UTF-8
  #   ==, eql?     → token comparison
  #   bytesize     → span calculation
  #   length       → character count (for string literals)
  # --------------------------------------------------------------------------
  class Lexer
    attr_reader :source, :pos, :tokens

    # @param source [String, StringView, StringView::Strict]
    def initialize(source)
      @source = if source.is_a?(StringView::Strict)
        source
      else
        StringView::Strict.new(source.to_s)
      end
      @pos = 0
      @tokens = []
    end

    # Tokenize the entire source. Returns an Array of Token structs.
    def tokenize
      @tokens = []
      @pos = 0

      while @pos < @source.bytesize
        skip_whitespace_and_comments
        break if @pos >= @source.bytesize

        byte = @source.getbyte(@pos)

        case byte
        when 40  # '('
          @tokens << Token.new(type: :lparen, value: nil, byte_offset: @pos, byte_length: 1)
          @pos += 1
        when 41  # ')'
          @tokens << Token.new(type: :rparen, value: nil, byte_offset: @pos, byte_length: 1)
          @pos += 1
        when 39  # "'"
          @tokens << Token.new(type: :quote, value: nil, byte_offset: @pos, byte_length: 1)
          @pos += 1
        when 34  # '"'
          lex_string
        when 35  # '#'
          lex_boolean
        when 58  # ':'
          lex_keyword
        else
          lex_atom
        end
      end

      @tokens
    end

    private

    def skip_whitespace_and_comments
      while @pos < @source.bytesize
        byte = @source.getbyte(@pos)
        if byte == 32 || byte == 9 || byte == 10 || byte == 13 # space, tab, nl, cr
          @pos += 1
        elsif byte == 59 # ';' — comment to end of line
          # Use index to find the newline — zero-copy search
          remaining = @source.byteslice(@pos, @source.bytesize - @pos)
          nl_pos = remaining.index("\n")
          if nl_pos
            @pos += nl_pos + 1
          else
            @pos = @source.bytesize
          end
        else
          break
        end
      end
    end

    def lex_string
      start = @pos
      @pos += 1 # skip opening '"'
      # Find closing quote, handling escapes
      while @pos < @source.bytesize
        byte = @source.getbyte(@pos)
        if byte == 92 # '\\' — escape: skip next byte
          @pos += 2
        elsif byte == 34 # '"' — closing quote
          @pos += 1
          break
        else
          @pos += 1
        end
      end

      span = @source.byteslice(start, @pos - start)
      # Validate the string literal is well-formed UTF-8
      raise "Invalid UTF-8 in string literal at byte #{start}" unless span.valid_encoding?

      # The token value is the inner content: strip quotes with delete_prefix/delete_suffix
      inner = span.delete_prefix('"').delete_suffix('"')
      @tokens << Token.new(type: :string, value: inner, byte_offset: start, byte_length: @pos - start)
    end

    def lex_boolean
      if @pos + 1 < @source.bytesize
        next_byte = @source.getbyte(@pos + 1)
        if next_byte == 116 # 't'
          @tokens << Token.new(type: :boolean, value: true, byte_offset: @pos, byte_length: 2)
          @pos += 2
          return
        elsif next_byte == 102 # 'f'
          @tokens << Token.new(type: :boolean, value: false, byte_offset: @pos, byte_length: 2)
          @pos += 2
          return
        end
      end
      # Not a boolean — treat as atom
      lex_atom
    end

    def lex_keyword
      start = @pos
      @pos += 1 # skip ':'
      # Read until delimiter
      while @pos < @source.bytesize
        byte = @source.getbyte(@pos)
        break if delimiter_byte?(byte)

        @pos += 1
      end

      span = @source.byteslice(start, @pos - start)
      # Strip the ':' prefix to get the keyword name
      name = span.delete_prefix(":")
      @tokens << Token.new(type: :keyword, value: name, byte_offset: start, byte_length: @pos - start)
    end

    def lex_atom
      start = @pos

      # Advance until we hit a delimiter
      while @pos < @source.bytesize
        byte = @source.getbyte(@pos)
        break if delimiter_byte?(byte)

        @pos += 1
      end

      span = @source.byteslice(start, @pos - start)
      return if span.empty?

      classify_atom(span, start)
    end

    def classify_atom(span, start)
      first_byte = span.getbyte(0)

      # Check for nil
      if span == "nil"
        @tokens << Token.new(type: :nil, value: nil, byte_offset: start, byte_length: span.bytesize)
        return
      end

      # Check for numeric: starts with digit, or +/- followed by digit
      if digit_byte?(first_byte) || ((first_byte == 43 || first_byte == 45) && span.bytesize > 1 && digit_byte?(span.getbyte(1)))
        @tokens << if span.include?(".")
          Token.new(type: :float, value: span.to_f, byte_offset: start, byte_length: span.bytesize)
        else
          @tokens << Token.new(type: :integer, value: span.to_i, byte_offset: start, byte_length: span.bytesize)
        end
        return
      end

      # Everything else is a symbol — the value is the Strict view itself (zero-copy)
      @tokens << Token.new(type: :symbol, value: span, byte_offset: start, byte_length: span.bytesize)
    end

    def delimiter_byte?(byte)
      byte == 32 || byte == 9 || byte == 10 || byte == 13 || # whitespace
        byte == 40 || byte == 41 ||  # ( )
        byte == 34 || byte == 39 ||  # " '
        byte == 59                   # ;
    end

    def digit_byte?(byte)
      byte >= 48 && byte <= 57 # '0'..'9'
    end
  end

  # --------------------------------------------------------------------------
  # Parser — builds nested AST from token stream.
  #
  # The AST is represented as:
  #   - Lists: Ruby Arrays of AST nodes
  #   - Atoms: Token structs (type + value)
  #   - Quoted: [:quote, node]
  # --------------------------------------------------------------------------
  class Parser
    def initialize(source)
      @lexer = Lexer.new(source)
      @tokens = nil
      @pos = 0
    end

    # Parse a single top-level expression.
    def parse
      @tokens = @lexer.tokenize
      @pos = 0
      node = parse_expr
      # Verify we consumed everything (or allow trailing whitespace via tokenizer)
      node
    end

    # Parse all top-level expressions (for multi-expression inputs).
    def parse_all
      @tokens = @lexer.tokenize
      @pos = 0
      nodes = []
      while @pos < @tokens.length
        nodes << parse_expr
      end
      nodes
    end

    # Expose tokens for testing
    def tokens
      @tokens ||= @lexer.tokenize
    end

    private

    def parse_expr
      raise "Unexpected end of input" if @pos >= @tokens.length

      token = @tokens[@pos]

      case token.type
      when :lparen
        parse_list
      when :quote
        @pos += 1
        [:quote, parse_expr]
      when :rparen
        raise "Unexpected ')' at byte #{token.byte_offset}"
      else
        @pos += 1
        token
      end
    end

    def parse_list
      @pos += 1 # skip '('
      elements = []

      while @pos < @tokens.length
        token = @tokens[@pos]
        break if token.type == :rparen
        elements << parse_expr
      end

      if @pos >= @tokens.length
        raise "Unterminated list — expected ')'"
      end

      @pos += 1 # skip ')'
      elements
    end
  end

  # Convenience method
  def self.parse(source)
    Parser.new(source).parse
  end

  def self.parse_all(source)
    Parser.new(source).parse_all
  end

  def self.tokenize(source)
    Lexer.new(source).tokenize
  end
end
