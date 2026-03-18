# frozen_string_literal: true

require "test_helper"

#
# Tests that verify the zero-copy transform methods allocate ZERO Strings.
# These methods (strip, lstrip, rstrip, chomp, chop, delete_prefix,
# delete_suffix, chr) return a new StringView that shares the same backing
# bytes — no String objects are created at all.
#
# We use ObjectSpace.count_objects to count exact String allocations.
#
class TestZeroStringAllocations < Minitest::Test
  def setup
    # Force a GC to get a clean baseline
    GC.start
  end

  # Helper: count String allocations during a block
  def string_allocations(&block)
    GC.disable
    # Count T_STRING objects before
    str_before = ObjectSpace.count_objects[:T_STRING]
    1000.times(&block)
    str_after = ObjectSpace.count_objects[:T_STRING]
    GC.enable
    ((str_after - str_before).to_f / 1000).round
  end

  # -------------------------------------------------------------------
  # strip / lstrip / rstrip — zero String allocations
  # -------------------------------------------------------------------

  def test_strip_zero_string_allocations
    sv = StringView.new("  hello  ")
    sv.strip # warm
    allocs = string_allocations { sv.strip }
    assert_equal(0, allocs, "strip should allocate 0 Strings, got #{allocs}")
  end

  def test_lstrip_zero_string_allocations
    sv = StringView.new("  hello  ")
    sv.lstrip # warm
    allocs = string_allocations { sv.lstrip }
    assert_equal(0, allocs, "lstrip should allocate 0 Strings, got #{allocs}")
  end

  def test_rstrip_zero_string_allocations
    sv = StringView.new("  hello  ")
    sv.rstrip # warm
    allocs = string_allocations { sv.rstrip }
    assert_equal(0, allocs, "rstrip should allocate 0 Strings, got #{allocs}")
  end

  # -------------------------------------------------------------------
  # chomp / chop — zero String allocations
  # -------------------------------------------------------------------

  def test_chomp_zero_string_allocations
    sv = StringView.new("hello\n")
    sv.chomp # warm
    allocs = string_allocations { sv.chomp }
    assert_equal(0, allocs, "chomp should allocate 0 Strings, got #{allocs}")
  end

  def test_chomp_with_separator_zero_string_allocations
    sv = StringView.new("hello!")
    sv.chomp("!") # warm
    allocs = string_allocations { sv.chomp("!") }
    assert_equal(0, allocs, "chomp('!') should allocate 0 Strings, got #{allocs}")
  end

  def test_chop_zero_string_allocations
    sv = StringView.new("hello")
    sv.chop # warm
    allocs = string_allocations { sv.chop }
    assert_equal(0, allocs, "chop should allocate 0 Strings, got #{allocs}")
  end

  # -------------------------------------------------------------------
  # delete_prefix / delete_suffix — zero String allocations
  # -------------------------------------------------------------------

  def test_delete_prefix_zero_string_allocations
    sv = StringView.new("hello world")
    sv.delete_prefix("hello ") # warm
    allocs = string_allocations { sv.delete_prefix("hello ") }
    assert_equal(0, allocs, "delete_prefix should allocate 0 Strings, got #{allocs}")
  end

  def test_delete_suffix_zero_string_allocations
    sv = StringView.new("hello world")
    sv.delete_suffix(" world") # warm
    allocs = string_allocations { sv.delete_suffix(" world") }
    assert_equal(0, allocs, "delete_suffix should allocate 0 Strings, got #{allocs}")
  end

  # -------------------------------------------------------------------
  # chr — zero String allocations
  # -------------------------------------------------------------------

  def test_chr_zero_string_allocations
    sv = StringView.new("hello")
    sv.chr # warm
    allocs = string_allocations { sv.chr }
    assert_equal(0, allocs, "chr should allocate 0 Strings, got #{allocs}")
  end

  # -------------------------------------------------------------------
  # ord / valid_encoding? — zero total allocations
  # -------------------------------------------------------------------

  def test_ord_zero_string_allocations
    sv = StringView.new("hello")
    sv.ord # warm
    allocs = string_allocations { sv.ord }
    assert_equal(0, allocs, "ord should allocate 0 Strings, got #{allocs}")
  end

  def test_valid_encoding_zero_string_allocations
    sv = StringView.new("hello")
    sv.valid_encoding? # warm
    allocs = string_allocations { sv.valid_encoding? }
    assert_equal(0, allocs, "valid_encoding? should allocate 0 Strings, got #{allocs}")
  end

  # -------------------------------------------------------------------
  # Chained operations — still zero String allocations
  # -------------------------------------------------------------------

  def test_strip_then_delete_prefix_zero_string_allocations
    sv = StringView.new("  hello world  ")
    sv.strip.delete_prefix("hello ") # warm
    allocs = string_allocations { sv.strip.delete_prefix("hello ") }
    assert_equal(
      0,
      allocs,
      "strip.delete_prefix should allocate 0 Strings, got #{allocs}",
    )
  end

  def test_chomp_then_delete_suffix_zero_string_allocations
    sv = StringView.new("hello world!\n")
    sv.chomp.delete_suffix("!") # warm
    allocs = string_allocations { sv.chomp.delete_suffix("!") }
    assert_equal(
      0,
      allocs,
      "chomp.delete_suffix should allocate 0 Strings, got #{allocs}",
    )
  end

  def test_strip_then_chomp_then_chr_zero_string_allocations
    sv = StringView.new("  hello\n  ")
    sv.strip.chomp.chr # warm
    allocs = string_allocations { sv.strip.chomp.chr }
    assert_equal(
      0,
      allocs,
      "strip.chomp.chr should allocate 0 Strings, got #{allocs}",
    )
  end

  # -------------------------------------------------------------------
  # Contrast: delegated methods DO allocate Strings
  # -------------------------------------------------------------------

  def test_upcase_allocates_strings
    sv = StringView.new("hello")
    sv.upcase # warm
    allocs = string_allocations { sv.upcase }
    assert_operator(
      allocs,
      :>=,
      1,
      "upcase should allocate at least 1 String (for the result)",
    )
  end

  def test_reverse_allocates_strings
    sv = StringView.new("hello")
    sv.reverse # warm
    allocs = string_allocations { sv.reverse }
    assert_operator(
      allocs,
      :>=,
      1,
      "reverse should allocate at least 1 String (for the result)",
    )
  end
end
