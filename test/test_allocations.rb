# frozen_string_literal: true

require "test_helper"

#
# Tests that verify the allocation behavior of StringView operations.
# These ensure that Tier 1 (zero-copy) operations don't allocate,
# Tier 2 (slicing) allocates exactly one StringView, and Tier 3
# (delegation) allocates at most one result String.
#
class TestAllocations < Minitest::Test
  def setup
    @backing = ("Hello, world! " * 10_000).freeze
    @sv = StringView.new(@backing)
    @slice = @sv[1000, 5000]

    # Warm up — first calls may allocate caches, method entries, etc.
    @sv.to_i
    @sv.to_f
    @sv.hex
    @sv.oct
    @sv.length
    @sv.bytesize
    @sv.include?("world")
    @sv.start_with?("Hello")
    @sv.end_with?("world")
    @sv.getbyte(0)
    @sv.ascii_only?
    @sv.empty?
    @sv.encoding
    @sv.eql?(@sv)
    @sv.hash
    @sv[0, 1]
    @sv.byteslice(0, 1)
  end

  # -------------------------------------------------------------------
  # Tier 1: Zero-copy reads — should allocate 0 objects
  # -------------------------------------------------------------------

  def test_bytesize_zero_alloc
    assert_allocations(0) { @sv.bytesize }
  end

  def test_length_zero_alloc
    assert_allocations(0) { @sv.length }
  end

  def test_size_zero_alloc
    assert_allocations(0) { @sv.size }
  end

  def test_empty_zero_alloc
    assert_allocations(0) { @sv.empty? }
  end

  def test_encoding_zero_alloc
    assert_allocations(0) { @sv.encoding }
  end

  def test_ascii_only_zero_alloc
    assert_allocations(0) { @sv.ascii_only? }
  end

  def test_getbyte_zero_alloc
    assert_allocations(0) { @sv.getbyte(0) }
  end

  def test_include_zero_alloc
    assert_allocations(0) { @sv.include?("world") }
  end

  def test_start_with_zero_alloc
    assert_allocations(0) { @sv.start_with?("Hello") }
  end

  def test_end_with_zero_alloc
    assert_allocations(0) { @sv.end_with?("world") }
  end

  def test_eq_string_view_zero_alloc
    other = StringView.new(@backing)
    _ = (@sv == other) # warm
    assert_allocations(0) { @sv == other }
  end

  def test_eq_string_zero_alloc
    assert_allocations(0) { @sv == @backing }
  end

  def test_cmp_zero_alloc
    other = StringView.new(@backing)
    _ = (@sv <=> other) # warm
    assert_allocations(0) { @sv <=> other }
  end

  def test_eql_zero_alloc
    other = StringView.new(@backing)
    _ = @sv.eql?(other) # warm
    assert_allocations(0) { @sv.eql?(other) }
  end

  def test_hash_zero_alloc
    assert_allocations(0) { @sv.hash }
  end

  def test_to_i_zero_alloc
    sv = StringView.new("12345xxxxxx", 0, 5)
    sv.to_i # warm
    assert_allocations(0) { sv.to_i }
  end

  def test_to_i_with_base_zero_alloc
    sv = StringView.new("ffxxxxxx", 0, 2)
    sv.to_i(16) # warm
    assert_allocations(0) { sv.to_i(16) }
  end

  def test_to_f_zero_alloc
    sv = StringView.new("3.14xxxxxx", 0, 4)
    sv.to_f # warm
    assert_allocations(0) { sv.to_f }
  end

  def test_hex_zero_alloc
    sv = StringView.new("ffxxxxxx", 0, 2)
    sv.hex # warm
    assert_allocations(0) { sv.hex }
  end

  def test_oct_zero_alloc
    sv = StringView.new("77xxxxxx", 0, 2)
    sv.oct # warm
    assert_allocations(0) { sv.oct }
  end

  # -------------------------------------------------------------------
  # Tier 1: Reads on a pre-existing slice — also zero alloc
  # -------------------------------------------------------------------

  def test_bytesize_on_slice_zero_alloc
    assert_allocations(0) { @slice.bytesize }
  end

  def test_length_on_slice_zero_alloc
    assert_allocations(0) { @slice.length }
  end

  def test_include_on_slice_zero_alloc
    assert_allocations(0) { @slice.include?("world") }
  end

  def test_start_with_on_slice_zero_alloc
    assert_allocations(0) { @slice.start_with?("Hello") }
  end

  def test_getbyte_on_slice_zero_alloc
    assert_allocations(0) { @slice.getbyte(0) }
  end

  # -------------------------------------------------------------------
  # Tier 2: Slicing — should allocate exactly 1 StringView (no byte copy)
  # -------------------------------------------------------------------

  def test_aref_integer_length_one_alloc
    assert_allocations(1) { @sv[1000, 5000] }
  end

  def test_aref_single_integer_one_alloc
    assert_allocations(1) { @sv[0] }
  end

  def test_aref_range_one_alloc
    assert_allocations(1) { @sv[0..100] }
  end

  def test_byteslice_one_alloc
    assert_allocations(1) { @sv.byteslice(1000, 5000) }
  end

  def test_byteslice_single_one_alloc
    assert_allocations(1) { @sv.byteslice(0) }
  end

  def test_chained_slice_two_allocs
    # Two slices = two StringView objects, still no byte copies
    assert_allocations(2) { @sv[1000, 5000][100, 200] }
  end

  def test_slice_returns_string_view
    result = @sv[1000, 5000]
    assert_instance_of(StringView, result)
  end

  # -------------------------------------------------------------------
  # Tier 3: Transform delegation — allocates result String(s) only
  # -------------------------------------------------------------------

  def test_to_s_one_alloc
    assert_max_allocations(1) { @sv.to_s }
  end

  def test_upcase_one_alloc
    sv = StringView.new("hello")
    sv.upcase # warm
    assert_max_allocations(2) { sv.upcase }
  end

  def test_downcase_one_alloc
    sv = StringView.new("HELLO")
    sv.downcase # warm
    assert_max_allocations(2) { sv.downcase }
  end

  def test_strip_one_alloc
    sv = StringView.new("  hello  ")
    sv.strip # warm
    assert_max_allocations(2) { sv.strip }
  end

  def test_split_allocates_array_plus_strings
    sv = StringView.new("a,b,c")
    sv.split(",") # warm
    # split returns 1 Array + N Strings, plus the shared string for delegation
    result = sv.split(",")
    assert_instance_of(Array, result)
    result.each { |s| assert_instance_of(String, s) }
  end

  # -------------------------------------------------------------------
  # Memory: slices don't copy bytes
  # -------------------------------------------------------------------

  def test_slice_memsize_is_small
    require "objspace"
    slice = @sv[50_000, 50_000]
    # StringView struct is small (< 300 bytes), not 50KB
    assert_operator(ObjectSpace.memsize_of(slice), :<, 300)
  end

  def test_string_slice_memsize_is_large
    require "objspace"
    # String inner slice copies bytes
    str_slice = @backing[50_000, 50_000]
    # String slice should be close to 50KB
    assert_operator(ObjectSpace.memsize_of(str_slice), :>, 40_000)
  end

  private

  # Assert that the block allocates exactly `expected` objects.
  # Runs the block `n` times and checks total allocations = expected * n.
  # Using multiple iterations reduces noise from one-time setup costs.
  def assert_allocations(expected, n: 1000, &block)
    GC.disable
    before = GC.stat(:total_allocated_objects)
    n.times(&block)
    after = GC.stat(:total_allocated_objects)
    GC.enable

    total = after - before
    per_call = total.to_f / n

    assert_equal(
      expected,
      per_call.round,
      "Expected #{expected} allocations per call, got #{per_call.round} " \
        "(#{total} total over #{n} iterations)",
    )
  end

  # Assert that the block allocates at most `max` objects per call.
  # Useful for Tier 3 methods where the exact count depends on Ruby internals.
  def assert_max_allocations(max, n: 1000, &block)
    GC.disable
    before = GC.stat(:total_allocated_objects)
    n.times(&block)
    after = GC.stat(:total_allocated_objects)
    GC.enable

    total = after - before
    per_call = total.to_f / n

    assert_operator(
      per_call.round,
      :<=,
      max,
      "Expected at most #{max} allocations per call, got #{per_call.round} " \
        "(#{total} total over #{n} iterations)",
    )
  end
end
