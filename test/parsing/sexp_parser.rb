# frozen_string_literal: true

require "string_view"

#
# StringView::SexpParser — an S-expression lexer and parser that can run
# in four modes to compare allocation strategies:
#
#   :string        — plain Ruby String (allocates substrings)
#   :string_view   — StringView (one alloc per view)
#   :strict        — StringView::Strict (one alloc per view, no accidental to_s)
#   :pool          — StringView::Pool (zero alloc in steady state)
#
# The grammar, token types, and AST structure are identical across all modes.
# Only the slice operation differs — how the lexer extracts a byte range from
# the source buffer.
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
#   comment    = ';' to end of line
#
# == Token types
#
#   :integer, :float, :string, :symbol, :keyword, :boolean, :nil,
#   :lparen, :rparen, :quote
#
module StringView::SexpParser
  Token = Struct.new(:type, :value, :byte_offset, :byte_length, keyword_init: true)

  MODES = [:string, :string_view, :strict, :pool].freeze

  # --------------------------------------------------------------------------
  # Lexer — tokenizes source into Token objects.
  #
  # The `mode` parameter controls how byte ranges are extracted:
  #
  #   :string      — source is a String, slicing via source.byteslice
  #   :string_view — source is a StringView, slicing via source.byteslice
  #   :strict      — source is a StringView::Strict, slicing via source.byteslice
  #   :pool        — source is a StringView::Strict, slicing via pool.view
  #
  # In all modes, the hot-path byte inspection uses the same methods:
  # getbyte, index, include?, bytesize, empty?, to_i, to_f, valid_encoding?
  # --------------------------------------------------------------------------
  class Lexer
    attr_reader :source, :pos, :tokens, :mode

    # @param source [String, StringView, StringView::Strict] the source to lex
    # @param mode [Symbol] one of :string, :string_view, :strict, :pool
    def initialize(source, mode: :strict)
      raise ArgumentError, "Unknown mode: #{mode}" unless MODES.include?(mode)

      @mode = mode

      # Normalize to a raw String for wrapping in the appropriate type.
      # StringView::Strict#to_s raises WouldAllocate, so use .materialize.
      raw = case source
      when StringView::Strict then source.materialize
      when StringView then source.to_s
      when String then source
      else source.to_s
      end
      raw = raw.freeze

      case mode
      when :string
        @source = raw
        @slicer = ->(off, len) { @source.byteslice(off, len) }
      when :string_view
        @source = StringView.new(raw)
        @slicer = ->(off, len) { @source.byteslice(off, len) }
      when :strict
        @source = StringView::Strict.new(raw)
        @slicer = ->(off, len) { @source.byteslice(off, len) }
      when :pool
        @source = StringView::Strict.new(raw)
        @pool = StringView::Pool.new(raw) if defined?(StringView::Pool)
        @slicer = if @pool
          ->(off, len) { @pool.view(off, len) }
        else
          # Pool not available — fall back to Strict
          ->(off, len) { @source.byteslice(off, len) }
        end
      end

      @pos = 0
      @tokens = []
    end

    # Tokenize the entire source. Returns an Array of Token structs.
    def tokenize
      @tokens = []
      @pos = 0
      @pool&.reset! if @mode == :pool

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

    # Extract a byte range from the source using the mode-appropriate strategy.
    def slice(offset, length)
      @slicer.call(offset, length)
    end

    def skip_whitespace_and_comments
      while @pos < @source.bytesize
        byte = @source.getbyte(@pos)
        if byte == 32 || byte == 9 || byte == 10 || byte == 13
          @pos += 1
        elsif byte == 59 # ';'
          remaining = slice(@pos, @source.bytesize - @pos)
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
      @pos += 1
      while @pos < @source.bytesize
        byte = @source.getbyte(@pos)
        if byte == 92
          @pos += 2
        elsif byte == 34
          @pos += 1
          break
        else
          @pos += 1
        end
      end

      span = slice(start, @pos - start)
      raise "Invalid UTF-8 in string literal at byte #{start}" unless span.valid_encoding?

      inner = span.delete_prefix('"').delete_suffix('"')
      @tokens << Token.new(type: :string, value: inner, byte_offset: start, byte_length: @pos - start)
    end

    def lex_boolean
      if @pos + 1 < @source.bytesize
        next_byte = @source.getbyte(@pos + 1)
        if next_byte == 116
          @tokens << Token.new(type: :boolean, value: true, byte_offset: @pos, byte_length: 2)
          @pos += 2
          return
        elsif next_byte == 102
          @tokens << Token.new(type: :boolean, value: false, byte_offset: @pos, byte_length: 2)
          @pos += 2
          return
        end
      end
      lex_atom
    end

    def lex_keyword
      start = @pos
      @pos += 1
      while @pos < @source.bytesize
        byte = @source.getbyte(@pos)
        break if delimiter_byte?(byte)

        @pos += 1
      end

      span = slice(start, @pos - start)
      name = span.delete_prefix(":")
      @tokens << Token.new(type: :keyword, value: name, byte_offset: start, byte_length: @pos - start)
    end

    def lex_atom
      start = @pos
      while @pos < @source.bytesize
        byte = @source.getbyte(@pos)
        break if delimiter_byte?(byte)

        @pos += 1
      end

      span = slice(start, @pos - start)
      return if span.empty?

      classify_atom(span, start)
    end

    def classify_atom(span, start)
      first_byte = span.getbyte(0)

      if span == "nil"
        @tokens << Token.new(type: :nil, value: nil, byte_offset: start, byte_length: span.bytesize)
        return
      end

      if digit_byte?(first_byte) || ((first_byte == 43 || first_byte == 45) && span.bytesize > 1 && digit_byte?(span.getbyte(1)))
        @tokens << if span.include?(".")
          Token.new(type: :float, value: span.to_f, byte_offset: start, byte_length: span.bytesize)
        else
          Token.new(type: :integer, value: span.to_i, byte_offset: start, byte_length: span.bytesize)
        end
        return
      end

      @tokens << Token.new(type: :symbol, value: span, byte_offset: start, byte_length: span.bytesize)
    end

    def delimiter_byte?(byte)
      byte == 32 || byte == 9 || byte == 10 || byte == 13 ||
        byte == 40 || byte == 41 ||
        byte == 34 || byte == 39 ||
        byte == 59
    end

    def digit_byte?(byte)
      byte >= 48 && byte <= 57
    end
  end

  # --------------------------------------------------------------------------
  # Parser — builds nested AST from token stream.
  # --------------------------------------------------------------------------
  class Parser
    def initialize(source, mode: :strict)
      @lexer = Lexer.new(source, mode: mode)
      @tokens = nil
      @pos = 0
    end

    def parse
      @tokens = @lexer.tokenize
      @pos = 0
      parse_expr
    end

    def parse_all
      @tokens = @lexer.tokenize
      @pos = 0
      nodes = []
      nodes << parse_expr while @pos < @tokens.length
      nodes
    end

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
      @pos += 1
      elements = []

      while @pos < @tokens.length
        break if @tokens[@pos].type == :rparen

        elements << parse_expr
      end

      raise "Unterminated list — expected ')'" if @pos >= @tokens.length

      @pos += 1
      elements
    end
  end

  # Convenience methods — default to :strict mode
  def self.parse(source, mode: :strict)
    Parser.new(source, mode: mode).parse
  end

  def self.parse_all(source, mode: :strict)
    Parser.new(source, mode: mode).parse_all
  end

  def self.tokenize(source, mode: :strict)
    Lexer.new(source, mode: mode).tokenize
  end
end
