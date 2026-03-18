# frozen_string_literal: true

require "test_helper"

class TestStringViewStrict < Minitest::Test
  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  def test_new_from_string
    sv = StringView::Strict.new("hello world")
    assert_instance_of(StringView::Strict, sv)
  end

  def test_is_a_string_view
    sv = StringView::Strict.new("hello world")
    assert_kind_of(StringView, sv)
  end

  def test_new_with_offset_and_length
    sv = StringView::Strict.new("hello world", 6, 5)
    assert_equal("world", sv.materialize)
  end

  # ---------------------------------------------------------------------------
  # Zero-copy reads — all work identically to StringView
  # ---------------------------------------------------------------------------

  def test_bytesize
    sv = StringView::Strict.new("hello")
    assert_equal(5, sv.bytesize)
  end

  def test_length
    sv = StringView::Strict.new("hello")
    assert_equal(5, sv.length)
  end

  def test_empty
    sv = StringView::Strict.new("")
    assert_predicate(sv, :empty?)
  end

  def test_encoding
    sv = StringView::Strict.new("hello")
    assert_equal(Encoding::UTF_8, sv.encoding)
  end

  def test_ascii_only
    sv = StringView::Strict.new("hello")
    assert_predicate(sv, :ascii_only?)
  end

  def test_include
    sv = StringView::Strict.new("hello world")
    assert_includes(sv, "world")
  end

  def test_start_with
    sv = StringView::Strict.new("hello world")
    assert(sv.start_with?("hello"))
  end

  def test_end_with
    sv = StringView::Strict.new("hello world")
    assert(sv.end_with?("world"))
  end

  def test_getbyte
    sv = StringView::Strict.new("hello")
    assert_equal(104, sv.getbyte(0))
  end

  def test_each_byte
    sv = StringView::Strict.new("hi")
    bytes = []
    sv.each_byte { |b| bytes << b }
    assert_equal([104, 105], bytes)
  end

  def test_bytes
    sv = StringView::Strict.new("hi")
    assert_equal([104, 105], sv.bytes)
  end

  def test_to_i
    sv = StringView::Strict.new("42")
    assert_equal(42, sv.to_i)
  end

  def test_to_f
    sv = StringView::Strict.new("3.14")
    assert_in_delta(3.14, sv.to_f)
  end

  def test_hex
    sv = StringView::Strict.new("ff")
    assert_equal(255, sv.hex)
  end

  def test_oct
    sv = StringView::Strict.new("77")
    assert_equal(63, sv.oct)
  end

  def test_ord
    sv = StringView::Strict.new("hello")
    assert_equal(104, sv.ord)
  end

  def test_valid_encoding
    sv = StringView::Strict.new("hello")
    assert_predicate(sv, :valid_encoding?)
  end

  # ---------------------------------------------------------------------------
  # Comparison — works with both StringView and StringView::Strict
  # ---------------------------------------------------------------------------

  def test_eq_with_string
    sv = StringView::Strict.new("hello")
    assert_equal(sv, "hello")
  end

  def test_eq_with_string_view
    sv = StringView::Strict.new("hello")
    other = StringView.new("hello")
    assert_equal(sv, other)
  end

  def test_eq_with_strict
    sv1 = StringView::Strict.new("hello")
    sv2 = StringView::Strict.new("hello")
    assert_equal(sv1, sv2)
  end

  def test_cmp_with_string
    sv = StringView::Strict.new("abc")
    assert_equal(-1, sv <=> "def")
  end

  def test_cmp_with_string_view
    sv = StringView::Strict.new("abc")
    other = StringView.new("def")
    assert_equal(-1, sv <=> other)
  end

  def test_eql_strict_to_strict
    sv1 = StringView::Strict.new("hello")
    sv2 = StringView::Strict.new("hello")
    assert(sv1.eql?(sv2))
  end

  def test_eql_strict_to_regular
    sv1 = StringView::Strict.new("hello")
    sv2 = StringView.new("hello")
    assert(sv1.eql?(sv2))
  end

  def test_hash_matches_regular
    sv1 = StringView::Strict.new("hello")
    sv2 = StringView.new("hello")
    assert_equal(sv1.hash, sv2.hash)
  end

  def test_usable_as_hash_key_interop
    h = {}
    sv1 = StringView::Strict.new("hello")
    sv2 = StringView.new("hello")
    h[sv1] = :found
    assert_equal(:found, h[sv2])
  end

  # ---------------------------------------------------------------------------
  # Slicing — returns StringView::Strict, not StringView
  # ---------------------------------------------------------------------------

  def test_slice_returns_strict
    sv = StringView::Strict.new("hello world")
    result = sv[6, 5]
    assert_instance_of(StringView::Strict, result)
    assert_equal("world", result.materialize)
  end

  def test_slice_single_returns_strict
    sv = StringView::Strict.new("hello")
    result = sv[0]
    assert_instance_of(StringView::Strict, result)
    assert_equal("h", result.materialize)
  end

  def test_slice_range_returns_strict
    sv = StringView::Strict.new("hello world")
    result = sv[0..4]
    assert_instance_of(StringView::Strict, result)
    assert_equal("hello", result.materialize)
  end

  def test_byteslice_returns_strict
    sv = StringView::Strict.new("hello world")
    result = sv.byteslice(6, 5)
    assert_instance_of(StringView::Strict, result)
    assert_equal("world", result.materialize)
  end

  def test_chained_slicing_stays_strict
    sv = StringView::Strict.new("hello world")
    result = sv[6, 5][0, 3]
    assert_instance_of(StringView::Strict, result)
    assert_equal("wor", result.materialize)
  end

  # ---------------------------------------------------------------------------
  # Zero-copy transforms — return StringView::Strict
  # ---------------------------------------------------------------------------

  def test_strip_returns_strict
    sv = StringView::Strict.new("  hello  ")
    result = sv.strip
    assert_instance_of(StringView::Strict, result)
    assert_equal("hello", result.materialize)
  end

  def test_lstrip_returns_strict
    sv = StringView::Strict.new("  hello")
    result = sv.lstrip
    assert_instance_of(StringView::Strict, result)
    assert_equal("hello", result.materialize)
  end

  def test_rstrip_returns_strict
    sv = StringView::Strict.new("hello  ")
    result = sv.rstrip
    assert_instance_of(StringView::Strict, result)
    assert_equal("hello", result.materialize)
  end

  def test_chomp_returns_strict
    sv = StringView::Strict.new("hello\n")
    result = sv.chomp
    assert_instance_of(StringView::Strict, result)
    assert_equal("hello", result.materialize)
  end

  def test_chop_returns_strict
    sv = StringView::Strict.new("hello")
    result = sv.chop
    assert_instance_of(StringView::Strict, result)
    assert_equal("hell", result.materialize)
  end

  def test_delete_prefix_returns_strict
    sv = StringView::Strict.new("hello world")
    result = sv.delete_prefix("hello ")
    assert_instance_of(StringView::Strict, result)
    assert_equal("world", result.materialize)
  end

  def test_delete_suffix_returns_strict
    sv = StringView::Strict.new("hello world")
    result = sv.delete_suffix(" world")
    assert_instance_of(StringView::Strict, result)
    assert_equal("hello", result.materialize)
  end

  def test_chr_returns_strict
    sv = StringView::Strict.new("hello")
    result = sv.chr
    assert_instance_of(StringView::Strict, result)
    assert_equal("h", result.materialize)
  end

  # ---------------------------------------------------------------------------
  # Chained zero-copy operations — all stay Strict
  # ---------------------------------------------------------------------------

  def test_chained_strip_delete_prefix_chr
    sv = StringView::Strict.new("  hello world  ")
    result = sv.strip.delete_prefix("hello ").chr
    assert_instance_of(StringView::Strict, result)
    assert_equal("w", result.materialize)
  end

  # ---------------------------------------------------------------------------
  # WouldAllocate — all allocating methods raise
  # ---------------------------------------------------------------------------

  def test_would_allocate_is_runtime_error
    assert(StringView::WouldAllocate < RuntimeError)
  end

  # Tier 3 transforms
  def test_upcase_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.upcase }
  end

  def test_downcase_raises
    sv = StringView::Strict.new("HELLO")
    assert_raises(StringView::WouldAllocate) { sv.downcase }
  end

  def test_capitalize_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.capitalize }
  end

  def test_swapcase_raises
    sv = StringView::Strict.new("Hello")
    assert_raises(StringView::WouldAllocate) { sv.swapcase }
  end

  def test_reverse_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.reverse }
  end

  def test_squeeze_raises
    sv = StringView::Strict.new("aaa")
    assert_raises(StringView::WouldAllocate) { sv.squeeze }
  end

  def test_encode_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.encode("ASCII") }
  end

  def test_gsub_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.gsub("l", "r") }
  end

  def test_sub_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.sub("l", "r") }
  end

  def test_tr_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.tr("l", "r") }
  end

  def test_tr_s_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.tr_s("l", "r") }
  end

  def test_delete_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.delete("l") }
  end

  def test_scan_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.scan(/l/) }
  end

  def test_split_raises
    sv = StringView::Strict.new("a,b,c")
    assert_raises(StringView::WouldAllocate) { sv.split(",") }
  end

  def test_center_raises
    sv = StringView::Strict.new("hi")
    assert_raises(StringView::WouldAllocate) { sv.center(10) }
  end

  def test_ljust_raises
    sv = StringView::Strict.new("hi")
    assert_raises(StringView::WouldAllocate) { sv.ljust(10) }
  end

  def test_rjust_raises
    sv = StringView::Strict.new("hi")
    assert_raises(StringView::WouldAllocate) { sv.rjust(10) }
  end

  def test_format_op_raises
    sv = StringView::Strict.new("hello %s")
    assert_raises(StringView::WouldAllocate) { sv % "world" }
  end

  def test_plus_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv + " world" }
  end

  def test_multiply_raises
    sv = StringView::Strict.new("ha")
    assert_raises(StringView::WouldAllocate) { sv * 3 }
  end

  def test_unpack1_raises
    sv = StringView::Strict.new("\x01\x02")
    assert_raises(StringView::WouldAllocate) { sv.unpack1("C*") }
  end

  def test_scrub_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.scrub }
  end

  def test_unicode_normalize_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.unicode_normalize }
  end

  def test_count_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.count("l") }
  end

  # index/rindex/byteindex/byterindex — string args work, regex raises

  def test_index_with_string_works
    sv = StringView::Strict.new("hello world")
    assert_equal(6, sv.index("world"))
  end

  def test_index_with_string_and_offset_works
    sv = StringView::Strict.new("hello hello")
    assert_equal(6, sv.index("hello", 1))
  end

  def test_index_with_regexp_raises
    sv = StringView::Strict.new("hello world")
    assert_raises(StringView::WouldAllocate) { sv.index(/world/) }
  end

  def test_rindex_with_string_works
    sv = StringView::Strict.new("hello hello")
    assert_equal(6, sv.rindex("hello"))
  end

  def test_rindex_with_string_and_offset_works
    sv = StringView::Strict.new("hello hello")
    assert_equal(0, sv.rindex("hello", 5))
  end

  def test_rindex_with_regexp_raises
    sv = StringView::Strict.new("hello world")
    assert_raises(StringView::WouldAllocate) { sv.rindex(/hello/) }
  end

  def test_byteindex_with_string_works
    sv = StringView::Strict.new("hello world")
    assert_equal(6, sv.byteindex("world"))
  end

  def test_byteindex_with_regexp_raises
    sv = StringView::Strict.new("hello world")
    assert_raises(StringView::WouldAllocate) { sv.byteindex(/world/) }
  end

  def test_byterindex_with_string_works
    sv = StringView::Strict.new("hello hello")
    assert_equal(6, sv.byterindex("hello"))
  end

  def test_byterindex_with_regexp_raises
    sv = StringView::Strict.new("hello world")
    assert_raises(StringView::WouldAllocate) { sv.byterindex(/hello/) }
  end

  def test_match_raises
    sv = StringView::Strict.new("hello world")
    assert_raises(StringView::WouldAllocate) { sv.match(/hello/) }
  end

  def test_match_p_raises
    sv = StringView::Strict.new("hello world")
    assert_raises(StringView::WouldAllocate) { sv.match?(/hello/) }
  end

  def test_match_operator_raises
    sv = StringView::Strict.new("hello world")
    assert_raises(StringView::WouldAllocate) { sv =~ /hello/ }
  end

  # Iteration that allocates strings
  def test_each_char_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.each_char { |c| } }
  end

  def test_chars_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.chars }
  end

  # to_str implicit coercion
  def test_to_str_raises
    sv = StringView::Strict.new("hello")
    # to_str is private but called internally for coercion
    assert_raises(StringView::WouldAllocate) { sv.send(:to_str) }
  end

  # ---------------------------------------------------------------------------
  # to_s / materialize — the explicit escape hatch
  # ---------------------------------------------------------------------------

  def test_to_s_raises
    sv = StringView::Strict.new("hello")
    assert_raises(StringView::WouldAllocate) { sv.to_s }
  end

  def test_materialize_works
    sv = StringView::Strict.new("hello")
    result = sv.materialize
    assert_instance_of(String, result)
    assert_equal("hello", result)
  end

  def test_inspect_works
    sv = StringView::Strict.new("hello")
    result = sv.inspect
    assert_instance_of(String, result)
    assert_includes(result, "hello")
  end

  # ---------------------------------------------------------------------------
  # reset! works
  # ---------------------------------------------------------------------------

  def test_reset
    sv = StringView::Strict.new("hello")
    sv.reset!("world", 0, 5)
    assert_equal("world", sv.materialize)
    assert_instance_of(StringView::Strict, sv)
  end

  # ---------------------------------------------------------------------------
  # WouldAllocate error message includes method name
  # ---------------------------------------------------------------------------

  def test_error_message_includes_method_name
    sv = StringView::Strict.new("hello")
    err = assert_raises(StringView::WouldAllocate) { sv.upcase }
    assert_includes(err.message, "upcase")
    assert_includes(err.message, "would allocate")
    assert_includes(err.message, ".materialize")
    assert_includes(err.message, ".reset!")
  end

  # ---------------------------------------------------------------------------
  # Multibyte works correctly
  # ---------------------------------------------------------------------------

  def test_multibyte_slicing
    sv = StringView::Strict.new("日本語テスト")
    result = sv[0, 2]
    assert_instance_of(StringView::Strict, result)
    assert_equal("日本", result.materialize)
  end

  def test_multibyte_length
    sv = StringView::Strict.new("café")
    assert_equal(4, sv.length)
  end

  def test_multibyte_chr
    sv = StringView::Strict.new("日本語")
    result = sv.chr
    assert_instance_of(StringView::Strict, result)
    assert_equal("日", result.materialize)
  end

  # ---------------------------------------------------------------------------
  # Zero allocations — same as StringView for zero-copy methods
  # ---------------------------------------------------------------------------

  def test_zero_alloc_reads
    sv = StringView::Strict.new("  hello  ")
    # Warm up — run enough times to trigger any one-time JIT/cache allocs
    10.times do
      sv.bytesize
      sv.length
      sv.empty?
      sv.include?("hello")
      sv.start_with?("  ")
      sv.end_with?("  ")
      sv.getbyte(0)
      sv.ascii_only?
      sv.hash
      sv == "  hello  "
    end

    n = 10_000
    GC.disable
    before = GC.stat(:total_allocated_objects)
    n.times do
      sv.bytesize
      sv.length
      sv.empty?
      sv.include?("hello")
      sv.start_with?("  ")
      sv.end_with?("  ")
      sv.getbyte(0)
      sv.ascii_only?
      sv.hash
      sv == "  hello  "
    end
    after = GC.stat(:total_allocated_objects)
    GC.enable

    per_call = ((after - before).to_f / n).round
    assert_equal(0, per_call, "Zero-copy reads should allocate 0 objects per iteration, got #{per_call}")
  end

  def test_strip_one_alloc_strict
    sv = StringView::Strict.new("  hello  ")
    sv.strip # warm
    GC.disable
    before = GC.stat(:total_allocated_objects)
    1000.times { sv.strip }
    after = GC.stat(:total_allocated_objects)
    GC.enable
    per_call = ((after - before).to_f / 1000).round
    assert_equal(1, per_call, "strip should allocate exactly 1 StringView::Strict, got #{per_call}")
  end

  def test_strip_result_is_strict
    sv = StringView::Strict.new("  hello  ")
    result = sv.strip
    assert_instance_of(StringView::Strict, result)
  end
end
