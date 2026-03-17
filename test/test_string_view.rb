# frozen_string_literal: true

require "test_helper"

class TestStringView < Minitest::Test
  # ---------------------------------------------------------------------------
  # Construction & Identity
  # ---------------------------------------------------------------------------

  def test_version
    refute_nil StringView::VERSION
  end

  def test_new_from_string
    sv = StringView.new("hello world")
    assert_instance_of StringView, sv
  end

  def test_new_freezes_backing_string
    str = +"mutable"
    StringView.new(str)
    assert_predicate str, :frozen?
  end

  def test_new_with_frozen_string
    str = "already frozen"
    sv = StringView.new(str)
    assert_equal "already frozen", sv.to_s
  end

  def test_new_requires_string_argument
    assert_raises(TypeError) { StringView.new(42) }
    assert_raises(TypeError) { StringView.new(nil) }
    assert_raises(TypeError) { StringView.new([]) }
  end

  def test_new_with_offset_and_length
    sv = StringView.new("hello world", 6, 5)
    assert_equal "world", sv.to_s
  end

  def test_new_with_offset_and_length_bounds_check
    assert_raises(ArgumentError) { StringView.new("hello", 0, 10) }
    assert_raises(ArgumentError) { StringView.new("hello", 6, 1) }
    assert_raises(ArgumentError) { StringView.new("hello", -1, 1) }
  end

  def test_inspect
    sv = StringView.new("hello world", 6, 5)
    result = sv.inspect
    assert_includes result, "StringView"
    assert_includes result, "world"
  end

  # ---------------------------------------------------------------------------
  # to_s / materialize
  # ---------------------------------------------------------------------------

  def test_to_s_returns_string
    sv = StringView.new("hello")
    result = sv.to_s
    assert_instance_of String, result
    assert_equal "hello", result
  end

  def test_to_s_on_slice_returns_correct_substring
    sv = StringView.new("hello world", 6, 5)
    assert_equal "world", sv.to_s
  end

  def test_to_s_returns_new_string_each_time
    sv = StringView.new("hello")
    a = sv.to_s
    b = sv.to_s
    refute_same a, b
  end

  def test_to_str_is_not_defined
    sv = StringView.new("hello")
    refute_respond_to sv, :to_str
  end

  # ---------------------------------------------------------------------------
  # Tier 1: Structural — bytesize, length, empty?, encoding, ascii_only?
  # ---------------------------------------------------------------------------

  def test_bytesize
    sv = StringView.new("hello")
    assert_equal 5, sv.bytesize
  end

  def test_bytesize_on_slice
    sv = StringView.new("hello world", 6, 5)
    assert_equal 5, sv.bytesize
  end

  def test_bytesize_multibyte
    str = "héllo"
    sv = StringView.new(str)
    assert_equal str.bytesize, sv.bytesize
  end

  def test_length
    sv = StringView.new("hello")
    assert_equal 5, sv.length
  end

  def test_length_multibyte
    str = "héllo"
    sv = StringView.new(str)
    assert_equal 5, sv.length
  end

  def test_size_is_alias_for_length
    sv = StringView.new("hello")
    assert_equal sv.length, sv.size
  end

  def test_empty_true
    sv = StringView.new("")
    assert_predicate sv, :empty?
  end

  def test_empty_false
    sv = StringView.new("x")
    refute_predicate sv, :empty?
  end

  def test_empty_on_zero_length_slice
    sv = StringView.new("hello", 3, 0)
    assert_predicate sv, :empty?
  end

  def test_encoding
    sv = StringView.new("hello".encode("UTF-8"))
    assert_equal Encoding::UTF_8, sv.encoding
  end

  def test_encoding_preserves_source
    str = "hello".encode("ASCII")
    sv = StringView.new(str)
    assert_equal Encoding::US_ASCII, sv.encoding
  end

  def test_ascii_only_true
    sv = StringView.new("hello")
    assert_predicate sv, :ascii_only?
  end

  def test_ascii_only_false
    sv = StringView.new("héllo")
    refute_predicate sv, :ascii_only?
  end

  # ---------------------------------------------------------------------------
  # Tier 1: Searching — include?, start_with?, end_with?, index, rindex
  # ---------------------------------------------------------------------------

  def test_include_true
    sv = StringView.new("hello world")
    assert sv.include?("world")
  end

  def test_include_false
    sv = StringView.new("hello world")
    refute sv.include?("xyz")
  end

  def test_include_on_slice
    sv = StringView.new("hello world", 6, 5)
    assert sv.include?("orl")
    refute sv.include?("hello")
  end

  def test_start_with_true
    sv = StringView.new("hello world")
    assert sv.start_with?("hello")
  end

  def test_start_with_false
    sv = StringView.new("hello world")
    refute sv.start_with?("world")
  end

  def test_start_with_multiple_prefixes
    sv = StringView.new("hello world")
    assert sv.start_with?("xyz", "hello")
  end

  def test_start_with_on_slice
    sv = StringView.new("hello world", 6, 5)
    assert sv.start_with?("world")
    refute sv.start_with?("hello")
  end

  def test_end_with_true
    sv = StringView.new("hello world")
    assert sv.end_with?("world")
  end

  def test_end_with_false
    sv = StringView.new("hello world")
    refute sv.end_with?("hello")
  end

  def test_end_with_multiple_suffixes
    sv = StringView.new("hello world")
    assert sv.end_with?("xyz", "world")
  end

  def test_end_with_on_slice
    sv = StringView.new("hello world", 6, 5)
    assert sv.end_with?("world")
    refute sv.end_with?("hello")
  end

  def test_index_found
    sv = StringView.new("hello world")
    assert_equal 6, sv.index("world")
  end

  def test_index_not_found
    sv = StringView.new("hello world")
    assert_nil sv.index("xyz")
  end

  def test_index_with_offset
    sv = StringView.new("hello hello")
    assert_equal 6, sv.index("hello", 1)
  end

  def test_index_on_slice
    sv = StringView.new("hello world", 6, 5)
    assert_equal 0, sv.index("world")
  end

  def test_rindex_found
    sv = StringView.new("hello hello")
    assert_equal 6, sv.rindex("hello")
  end

  def test_rindex_not_found
    sv = StringView.new("hello world")
    assert_nil sv.rindex("xyz")
  end

  def test_rindex_with_offset
    sv = StringView.new("hello hello")
    assert_equal 0, sv.rindex("hello", 5)
  end

  def test_getbyte
    sv = StringView.new("hello")
    assert_equal 104, sv.getbyte(0) # 'h'
    assert_equal 111, sv.getbyte(4) # 'o'
  end

  def test_getbyte_on_slice
    sv = StringView.new("hello world", 6, 5)
    assert_equal 119, sv.getbyte(0) # 'w'
  end

  def test_getbyte_out_of_range
    sv = StringView.new("hello")
    assert_nil sv.getbyte(5)
    assert_nil sv.getbyte(-6)
  end

  def test_getbyte_negative_index
    sv = StringView.new("hello")
    assert_equal 111, sv.getbyte(-1) # 'o'
  end

  def test_byteindex
    sv = StringView.new("hello world")
    assert_equal 6, sv.byteindex("world")
  end

  def test_byteindex_not_found
    sv = StringView.new("hello world")
    assert_nil sv.byteindex("xyz")
  end

  def test_byteindex_with_offset
    sv = StringView.new("hello hello")
    assert_equal 6, sv.byteindex("hello", 1)
  end

  def test_byterindex
    sv = StringView.new("hello hello")
    assert_equal 6, sv.byterindex("hello")
  end

  def test_byterindex_not_found
    sv = StringView.new("hello world")
    assert_nil sv.byterindex("xyz")
  end

  # ---------------------------------------------------------------------------
  # Tier 1: Iteration — each_byte, each_char, bytes, chars
  # ---------------------------------------------------------------------------

  def test_each_byte
    sv = StringView.new("hi")
    bytes = []
    sv.each_byte { |b| bytes << b }
    assert_equal [104, 105], bytes
  end

  def test_each_byte_on_slice
    sv = StringView.new("hello", 1, 3)
    bytes = []
    sv.each_byte { |b| bytes << b }
    assert_equal [101, 108, 108], bytes # "ell"
  end

  def test_each_byte_returns_enumerator_without_block
    sv = StringView.new("hi")
    enum = sv.each_byte
    assert_instance_of Enumerator, enum
    assert_equal [104, 105], enum.to_a
  end

  def test_each_char
    sv = StringView.new("hi")
    chars = []
    sv.each_char { |c| chars << c }
    assert_equal ["h", "i"], chars
  end

  def test_each_char_multibyte
    sv = StringView.new("héllo")
    chars = []
    sv.each_char { |c| chars << c }
    assert_equal ["h", "é", "l", "l", "o"], chars
  end

  def test_each_char_returns_enumerator_without_block
    sv = StringView.new("hi")
    enum = sv.each_char
    assert_instance_of Enumerator, enum
    assert_equal ["h", "i"], enum.to_a
  end

  def test_bytes
    sv = StringView.new("hi")
    assert_equal [104, 105], sv.bytes
  end

  def test_chars
    sv = StringView.new("héllo")
    assert_equal ["h", "é", "l", "l", "o"], sv.chars
  end

  # ---------------------------------------------------------------------------
  # Tier 1: Pattern matching — match, match?, =~
  # ---------------------------------------------------------------------------

  def test_match_returns_matchdata
    sv = StringView.new("hello world")
    m = sv.match(/(\w+)\s(\w+)/)
    assert_instance_of MatchData, m
    assert_equal "hello", m[1]
    assert_equal "world", m[2]
  end

  def test_match_no_match
    sv = StringView.new("hello")
    assert_nil sv.match(/xyz/)
  end

  def test_match_on_slice
    sv = StringView.new("hello world", 6, 5)
    m = sv.match(/(\w+)/)
    assert_equal "world", m[1]
  end

  def test_match_p_true
    sv = StringView.new("hello world")
    assert sv.match?(/hello/)
  end

  def test_match_p_false
    sv = StringView.new("hello world")
    refute sv.match?(/xyz/)
  end

  def test_match_p_on_slice
    sv = StringView.new("hello world", 6, 5)
    assert sv.match?(/world/)
    refute sv.match?(/hello/)
  end

  def test_match_operator
    sv = StringView.new("hello world")
    assert_equal 6, sv =~ /world/
  end

  def test_match_operator_no_match
    sv = StringView.new("hello world")
    assert_nil(sv =~ /xyz/)
  end

  # ---------------------------------------------------------------------------
  # Tier 1: Numeric conversions — to_i, to_f, hex, oct
  # ---------------------------------------------------------------------------

  def test_to_i
    sv = StringView.new("42")
    assert_equal 42, sv.to_i
  end

  def test_to_i_with_base
    sv = StringView.new("ff")
    assert_equal 255, sv.to_i(16)
  end

  def test_to_i_non_numeric
    sv = StringView.new("hello")
    assert_equal 0, sv.to_i
  end

  def test_to_i_on_slice
    sv = StringView.new("abc42def", 3, 2)
    assert_equal 42, sv.to_i
  end

  def test_to_f
    sv = StringView.new("3.14")
    assert_in_delta 3.14, sv.to_f
  end

  def test_to_f_non_numeric
    sv = StringView.new("hello")
    assert_in_delta 0.0, sv.to_f
  end

  def test_hex
    sv = StringView.new("ff")
    assert_equal 255, sv.hex
  end

  def test_oct
    sv = StringView.new("77")
    assert_equal 63, sv.oct
  end

  # ---------------------------------------------------------------------------
  # Tier 1: Comparison — ==, <=>, eql?, hash
  # ---------------------------------------------------------------------------

  def test_eq_with_same_content
    sv1 = StringView.new("hello")
    sv2 = StringView.new("hello")
    assert_equal sv1, sv2
  end

  def test_eq_with_string
    sv = StringView.new("hello")
    assert_equal sv, "hello"
  end

  def test_eq_string_equals_string_view
    sv = StringView.new("hello")
    # String#== should not recognize StringView (no to_str)
    refute_equal "hello", sv
  end

  def test_eq_different_content
    sv1 = StringView.new("hello")
    sv2 = StringView.new("world")
    refute_equal sv1, sv2
  end

  def test_eq_with_slice
    sv = StringView.new("hello world", 6, 5)
    assert_equal sv, "world"
  end

  def test_cmp_equal
    sv1 = StringView.new("hello")
    sv2 = StringView.new("hello")
    assert_equal 0, sv1 <=> sv2
  end

  def test_cmp_less
    sv1 = StringView.new("abc")
    sv2 = StringView.new("def")
    assert_equal(-1, sv1 <=> sv2)
  end

  def test_cmp_greater
    sv1 = StringView.new("def")
    sv2 = StringView.new("abc")
    assert_equal 1, sv1 <=> sv2
  end

  def test_cmp_with_string
    sv = StringView.new("hello")
    assert_equal 0, sv <=> "hello"
  end

  def test_eql
    sv1 = StringView.new("hello")
    sv2 = StringView.new("hello")
    assert sv1.eql?(sv2)
  end

  def test_eql_with_string
    sv = StringView.new("hello")
    # eql? is stricter — should not cross types
    refute sv.eql?("hello")
  end

  def test_hash_equal_for_same_content
    sv1 = StringView.new("hello")
    sv2 = StringView.new("hello")
    assert_equal sv1.hash, sv2.hash
  end

  def test_hash_differs_for_different_content
    sv1 = StringView.new("hello")
    sv2 = StringView.new("world")
    # Not guaranteed but extremely likely
    refute_equal sv1.hash, sv2.hash
  end

  def test_usable_as_hash_key
    h = {}
    sv1 = StringView.new("hello")
    sv2 = StringView.new("hello")
    h[sv1] = :found
    assert_equal :found, h[sv2]
  end

  # ---------------------------------------------------------------------------
  # Tier 2: Slicing — [], slice, byteslice (returns StringView)
  # ---------------------------------------------------------------------------

  def test_aref_integer_index
    sv = StringView.new("hello")
    result = sv[1]
    assert_instance_of StringView, result
    assert_equal "e", result.to_s
  end

  def test_aref_negative_index
    sv = StringView.new("hello")
    result = sv[-1]
    assert_instance_of StringView, result
    assert_equal "o", result.to_s
  end

  def test_aref_out_of_range
    sv = StringView.new("hello")
    assert_nil sv[10]
    assert_nil sv[-10]
  end

  def test_aref_integer_with_length
    sv = StringView.new("hello world")
    result = sv[6, 5]
    assert_instance_of StringView, result
    assert_equal "world", result.to_s
  end

  def test_aref_range
    sv = StringView.new("hello world")
    result = sv[0..4]
    assert_instance_of StringView, result
    assert_equal "hello", result.to_s
  end

  def test_aref_range_exclusive
    sv = StringView.new("hello world")
    result = sv[0...5]
    assert_instance_of StringView, result
    assert_equal "hello", result.to_s
  end

  def test_aref_string_pattern
    sv = StringView.new("hello world")
    result = sv["world"]
    assert_instance_of StringView, result
    assert_equal "world", result.to_s
  end

  def test_aref_string_not_found
    sv = StringView.new("hello world")
    assert_nil sv["xyz"]
  end

  def test_aref_regex
    sv = StringView.new("hello world")
    result = sv[/\w+$/]
    assert_instance_of StringView, result
    assert_equal "world", result.to_s
  end

  def test_aref_regex_not_found
    sv = StringView.new("hello world")
    assert_nil sv[/\d+/]
  end

  def test_aref_chained_slicing
    sv = StringView.new("hello world")
    result = sv[6, 5][0, 3]
    assert_instance_of StringView, result
    assert_equal "wor", result.to_s
  end

  def test_slice_is_alias_for_aref
    sv = StringView.new("hello world")
    assert_equal sv[6, 5].to_s, sv.slice(6, 5).to_s
  end

  def test_byteslice_basic
    sv = StringView.new("hello world")
    result = sv.byteslice(6, 5)
    assert_instance_of StringView, result
    assert_equal "world", result.to_s
  end

  def test_byteslice_with_range
    sv = StringView.new("hello world")
    result = sv.byteslice(0..4)
    assert_instance_of StringView, result
    assert_equal "hello", result.to_s
  end

  def test_byteslice_on_slice
    sv = StringView.new("hello world", 6, 5)
    result = sv.byteslice(0, 3)
    assert_instance_of StringView, result
    assert_equal "wor", result.to_s
  end

  # ---------------------------------------------------------------------------
  # Tier 3: Transform methods — return String, not StringView
  # ---------------------------------------------------------------------------

  def test_upcase
    sv = StringView.new("hello")
    result = sv.upcase
    assert_instance_of String, result
    assert_equal "HELLO", result
  end

  def test_downcase
    sv = StringView.new("HELLO")
    result = sv.downcase
    assert_instance_of String, result
    assert_equal "hello", result
  end

  def test_capitalize
    sv = StringView.new("hello world")
    result = sv.capitalize
    assert_instance_of String, result
    assert_equal "Hello world", result
  end

  def test_swapcase
    sv = StringView.new("Hello")
    result = sv.swapcase
    assert_instance_of String, result
    assert_equal "hELLO", result
  end

  def test_strip
    sv = StringView.new("  hello  ")
    result = sv.strip
    assert_instance_of String, result
    assert_equal "hello", result
  end

  def test_lstrip
    sv = StringView.new("  hello  ")
    result = sv.lstrip
    assert_instance_of String, result
    assert_equal "hello  ", result
  end

  def test_rstrip
    sv = StringView.new("  hello  ")
    result = sv.rstrip
    assert_instance_of String, result
    assert_equal "  hello", result
  end

  def test_chomp
    sv = StringView.new("hello\n")
    result = sv.chomp
    assert_instance_of String, result
    assert_equal "hello", result
  end

  def test_chop
    sv = StringView.new("hello")
    result = sv.chop
    assert_instance_of String, result
    assert_equal "hell", result
  end

  def test_reverse
    sv = StringView.new("hello")
    result = sv.reverse
    assert_instance_of String, result
    assert_equal "olleh", result
  end

  def test_squeeze
    sv = StringView.new("aaabbbccc")
    result = sv.squeeze
    assert_instance_of String, result
    assert_equal "abc", result
  end

  def test_gsub
    sv = StringView.new("hello world")
    result = sv.gsub(/o/, "0")
    assert_instance_of String, result
    assert_equal "hell0 w0rld", result
  end

  def test_sub
    sv = StringView.new("hello world")
    result = sv.sub(/o/, "0")
    assert_instance_of String, result
    assert_equal "hell0 world", result
  end

  def test_tr
    sv = StringView.new("hello")
    result = sv.tr("el", "ip")
    assert_instance_of String, result
    assert_equal "hippo", result
  end

  def test_split
    sv = StringView.new("a,b,c")
    result = sv.split(",")
    assert_instance_of Array, result
    assert_equal ["a", "b", "c"], result
  end

  def test_scan
    sv = StringView.new("hello world")
    result = sv.scan(/\w+/)
    assert_equal ["hello", "world"], result
  end

  def test_count
    sv = StringView.new("hello world")
    # String#count counts individual character occurrences: l=3, o=2 = 5
    assert_equal 5, sv.count("lo")
  end

  def test_delete
    sv = StringView.new("hello")
    result = sv.delete("l")
    assert_instance_of String, result
    assert_equal "heo", result
  end

  def test_center
    sv = StringView.new("hi")
    result = sv.center(10)
    assert_instance_of String, result
    assert_equal "    hi    ", result
  end

  def test_ljust
    sv = StringView.new("hi")
    result = sv.ljust(10)
    assert_instance_of String, result
    assert_equal "hi        ", result
  end

  def test_rjust
    sv = StringView.new("hi")
    result = sv.rjust(10)
    assert_instance_of String, result
    assert_equal "        hi", result
  end

  def test_replace_format_operator
    sv = StringView.new("hello %s")
    result = sv % "world"
    assert_instance_of String, result
    assert_equal "hello world", result
  end

  def test_plus
    sv = StringView.new("hello")
    result = sv + " world"
    assert_instance_of String, result
    assert_equal "hello world", result
  end

  def test_multiply
    sv = StringView.new("ha")
    result = sv * 3
    assert_instance_of String, result
    assert_equal "hahaha", result
  end

  def test_encode
    sv = StringView.new("hello")
    result = sv.encode("ASCII")
    assert_instance_of String, result
    assert_equal Encoding::US_ASCII, result.encoding
  end

  def test_unpack1
    sv = StringView.new("\x01\x02")
    result = sv.unpack1("C*")
    assert_equal 1, result
  end

  def test_transform_on_slice
    sv = StringView.new("hello world", 6, 5)
    assert_equal "WORLD", sv.upcase
    assert_equal "dlrow", sv.reverse
  end

  # ---------------------------------------------------------------------------
  # Frozen / bang methods
  # ---------------------------------------------------------------------------

  def test_frozen
    sv = StringView.new("hello")
    assert_predicate sv, :frozen?
  end

  def test_bang_methods_raise
    sv = StringView.new("hello")
    assert_raises(FrozenError) { sv.upcase! }
    assert_raises(FrozenError) { sv.downcase! }
    assert_raises(FrozenError) { sv.gsub!(/o/, "0") }
    assert_raises(FrozenError) { sv.sub!(/o/, "0") }
    assert_raises(FrozenError) { sv.strip! }
    assert_raises(FrozenError) { sv.lstrip! }
    assert_raises(FrozenError) { sv.rstrip! }
    assert_raises(FrozenError) { sv.chomp!("\n") }
    assert_raises(FrozenError) { sv.chop! }
    assert_raises(FrozenError) { sv.squeeze! }
    assert_raises(FrozenError) { sv.tr!("a", "b") }
    assert_raises(FrozenError) { sv.delete!("l") }
    assert_raises(FrozenError) { sv.replace("x") }
    assert_raises(FrozenError) { sv.reverse! }
    assert_raises(FrozenError) { sv.capitalize! }
    assert_raises(FrozenError) { sv.swapcase! }
  end

  def test_slice_bang_raises
    sv = StringView.new("hello")
    assert_raises(FrozenError) { sv.slice!(0) }
  end

  # ---------------------------------------------------------------------------
  # method_missing safety net
  # ---------------------------------------------------------------------------

  def test_method_missing_for_string_method_raises_not_implemented
    sv = StringView.new("hello")
    # Pick a String method we haven't implemented
    assert_raises(NotImplementedError) { sv.crypt("ab") }
  end

  def test_method_missing_for_non_string_method_raises_no_method
    sv = StringView.new("hello")
    assert_raises(NoMethodError) { sv.totally_bogus_method }
  end

  def test_respond_to_missing_for_string_methods
    sv = StringView.new("hello")
    # String methods that exist but aren't natively implemented should
    # still show as not-respond_to, since they raise NotImplementedError
    refute_respond_to sv, :crypt
  end

  # ---------------------------------------------------------------------------
  # Encoding-aware behavior
  # ---------------------------------------------------------------------------

  def test_multibyte_length_vs_bytesize
    str = "café"
    sv = StringView.new(str)
    assert_equal 4, sv.length
    assert_equal str.bytesize, sv.bytesize
    assert sv.bytesize > sv.length
  end

  def test_multibyte_slicing
    sv = StringView.new("café latte")
    result = sv[0, 4]
    assert_instance_of StringView, result
    assert_equal "café", result.to_s
  end

  def test_multibyte_index
    sv = StringView.new("café latte")
    assert_equal 5, sv.index("latte")
  end

  # ---------------------------------------------------------------------------
  # Zero-copy verification (structural)
  # ---------------------------------------------------------------------------

  def test_slice_shares_backing
    # Two slices from the same source should both be StringViews
    # and produce correct content
    sv = StringView.new("hello world")
    a = sv[0, 5]
    b = sv[6, 5]
    assert_instance_of StringView, a
    assert_instance_of StringView, b
    assert_equal "hello", a.to_s
    assert_equal "world", b.to_s
  end

  def test_deeply_nested_slicing
    sv = StringView.new("abcdefghij")
    s1 = sv[2, 6]       # "cdefgh"
    s2 = s1[1, 4]       # "defg"
    s3 = s2[1, 2]       # "ef"
    assert_equal "ef", s3.to_s
  end

  # ---------------------------------------------------------------------------
  # Comparable / Enumerable integration
  # ---------------------------------------------------------------------------

  def test_comparable_operators
    sv1 = StringView.new("abc")
    sv2 = StringView.new("def")
    assert_operator sv1, :<, sv2
    assert_operator sv2, :>, sv1
    assert_operator sv1, :<=, sv1
    assert_operator sv1, :>=, sv1
  end

  # ---------------------------------------------------------------------------
  # reset! — re-point the view at a different backing/offset/length
  # ---------------------------------------------------------------------------

  def test_reset_basic
    sv = StringView.new("hello world")
    new_backing = "goodbye"
    sv.reset!(new_backing, 0, 7)
    assert_equal "goodbye", sv.to_s
  end

  def test_reset_freezes_new_backing
    sv = StringView.new("hello")
    new_backing = +"mutable string"
    sv.reset!(new_backing, 0, 14)
    assert_predicate new_backing, :frozen?
  end

  def test_reset_with_offset_and_length
    sv = StringView.new("hello")
    sv.reset!("goodbye world", 8, 5)
    assert_equal "world", sv.to_s
    assert_equal 5, sv.bytesize
  end

  def test_reset_bounds_check
    sv = StringView.new("hello")
    assert_raises(ArgumentError) { sv.reset!("hi", 0, 10) }
    assert_raises(ArgumentError) { sv.reset!("hi", 3, 1) }
    assert_raises(ArgumentError) { sv.reset!("hi", -1, 1) }
  end

  def test_reset_requires_string
    sv = StringView.new("hello")
    assert_raises(TypeError) { sv.reset!(42, 0, 1) }
    assert_raises(TypeError) { sv.reset!(nil, 0, 0) }
  end

  def test_reset_returns_self
    sv = StringView.new("hello")
    result = sv.reset!("world", 0, 5)
    assert_same sv, result
  end

  def test_reset_updates_all_properties
    sv = StringView.new("hello world", 6, 5)
    assert_equal "world", sv.to_s
    assert_equal 5, sv.length
    assert_equal 5, sv.bytesize

    sv.reset!("café latte", 0, 6) # "café " (5 chars, 6 bytes because é is 2 bytes)
    assert_equal "café ", sv.to_s
    assert_equal 6, sv.bytesize
  end

  def test_reset_allows_slicing_after
    sv = StringView.new("hello")
    sv.reset!("goodbye world", 0, 13)
    result = sv[8, 5]
    assert_instance_of StringView, result
    assert_equal "world", result.to_s
  end

  def test_reset_with_zero_length
    sv = StringView.new("hello")
    sv.reset!("anything", 3, 0)
    assert_predicate sv, :empty?
    assert_equal "", sv.to_s
  end

  # ---------------------------------------------------------------------------
  # GC safety — strong marks keep the backing alive
  # ---------------------------------------------------------------------------

  def test_view_survives_gc_without_external_reference
    sv = StringView.new(+"hello world")
    GC.start
    GC.start
    # View keeps backing alive — still works
    assert_equal "hello world", sv.to_s
    assert_equal 11, sv.bytesize
    assert sv.include?("world")
  end

  def test_multiple_views_into_same_backing
    str = +"shared backing string"
    sv1 = StringView.new(str)
    sv2 = StringView.new(str, 7, 7) # "backing"

    GC.start
    assert_equal "shared backing string", sv1.to_s
    assert_equal "backing", sv2.to_s
  end
end
