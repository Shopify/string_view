# frozen_string_literal: true

require "test_helper"
require "string_view/core_ext"

class TestCoreExt < Minitest::Test
  # ---------------------------------------------------------------------------
  # Basic functionality
  # ---------------------------------------------------------------------------

  def test_view_returns_string_view
    str = "Hello, World!"
    sv = str.view(0, 5)
    assert_instance_of(StringView, sv)
  end

  def test_view_content
    str = "Hello, World!"
    sv = str.view(0, 5)
    assert_equal("Hello", sv.to_s)
  end

  def test_view_with_offset
    str = "Hello, World!"
    sv = str.view(7, 5)
    assert_equal("World", sv.to_s)
  end

  def test_view_full_string
    str = "Hello"
    sv = str.view(0, str.bytesize)
    assert_equal("Hello", sv.to_s)
  end

  def test_view_empty_range
    str = "Hello"
    sv = str.view(0, 0)
    assert_equal("", sv.to_s)
  end

  def test_view_single_byte
    str = "Hello"
    sv = str.view(1, 1)
    assert_equal("e", sv.to_s)
  end

  # ---------------------------------------------------------------------------
  # Pool reuse — same string should reuse the same pool
  # ---------------------------------------------------------------------------

  def test_multiple_views_on_same_string
    str = "Hello, World!"
    v1 = str.view(0, 5)
    v2 = str.view(7, 5)
    assert_equal("Hello", v1.to_s)
    assert_equal("World", v2.to_s)
  end

  def test_pool_is_reused_across_calls
    str = "Hello, World!"
    # First call creates the pool, subsequent calls reuse it.
    # We can't inspect the ivar directly (it's hidden), but we can
    # verify that many views work without issues.
    views = 100.times.map { |i| str.view(0, [i, str.bytesize].min) }
    assert_equal(100, views.length)
    assert_equal("Hello, Wor", views[10].to_s)
  end

  # ---------------------------------------------------------------------------
  # Hidden ivar — pool should not be visible from Ruby
  # ---------------------------------------------------------------------------

  def test_pool_ivar_not_visible
    str = "Hello, World!"
    str.view(0, 5) # trigger pool creation
    refute_includes(str.instance_variables.map(&:to_s), "__sv_pool")
    refute_includes(str.instance_variables.map(&:to_s), "@__sv_pool")
  end

  def test_pool_ivar_not_accessible_via_instance_variable_get
    str = "Hello, World!"
    str.view(0, 5)
    assert_nil(str.instance_variable_get(:@__sv_pool))
  end

  # ---------------------------------------------------------------------------
  # String IS frozen by view
  # ---------------------------------------------------------------------------

  def test_view_freezes_string
    str = +"Hello, World!"
    str.view(0, 5)
    assert_predicate(str, :frozen?)
  end

  # ---------------------------------------------------------------------------
  # Works with frozen strings too
  # ---------------------------------------------------------------------------

  def test_view_on_frozen_string
    str = "Hello, World!"
    sv = str.view(0, 5)
    assert_equal("Hello", sv.to_s)
  end

  def test_view_on_frozen_string_literal
    sv = "Hello, World!".view(0, 5)
    assert_equal("Hello", sv.to_s)
  end

  # ---------------------------------------------------------------------------
  # Bounds checking
  # ---------------------------------------------------------------------------

  def test_view_negative_offset_raises
    str = "Hello"
    assert_raises(ArgumentError) { str.view(-1, 1) }
  end

  def test_view_negative_length_raises
    str = "Hello"
    assert_raises(ArgumentError) { str.view(0, -1) }
  end

  def test_view_offset_past_end_raises
    str = "Hello"
    assert_raises(ArgumentError) { str.view(6, 0) }
  end

  def test_view_length_overflows_raises
    str = "Hello"
    assert_raises(ArgumentError) { str.view(3, 3) }
  end

  def test_view_exact_end_boundary
    str = "Hello"
    sv = str.view(5, 0)
    assert_equal("", sv.to_s)
  end

  # ---------------------------------------------------------------------------
  # UTF-8 / multibyte
  # ---------------------------------------------------------------------------

  def test_view_utf8_byte_offsets
    str = "日本語テスト"
    # Each character is 3 bytes in UTF-8
    sv = str.view(0, 3)
    assert_equal("日", sv.to_s)
  end

  def test_view_utf8_middle
    str = "日本語テスト"
    sv = str.view(6, 6) # bytes 6..11 = "語テ"
    assert_equal("語テ", sv.to_s)
  end

  def test_view_preserves_encoding
    str = "Hello"
    sv = str.view(0, 5)
    assert_equal(str.encoding, sv.encoding)
  end

  def test_view_binary_encoding
    str = "\x00\x01\xFF\xFE".b
    sv = str.view(1, 2)
    assert_equal("\x01\xFF".b, sv.to_s)
    assert_equal(Encoding::ASCII_8BIT, sv.encoding)
  end

  # ---------------------------------------------------------------------------
  # Different strings get different pools
  # ---------------------------------------------------------------------------

  def test_different_strings_independent
    s1 = +"Hello"
    s2 = +"World"
    v1 = s1.view(0, 5)
    v2 = s2.view(0, 5)
    assert_equal("Hello", v1.to_s)
    assert_equal("World", v2.to_s)
  end

  # ---------------------------------------------------------------------------
  # String is frozen after view — mutation is not possible
  # ---------------------------------------------------------------------------

  def test_string_frozen_after_view
    str = +"Hello"
    str.view(0, 5)
    assert_predicate(str, :frozen?)
    assert_raises(FrozenError) { str.replace("World") }
  end
end
