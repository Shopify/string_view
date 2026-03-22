# frozen_string_literal: true

require "test_helper"
require "string_view/core_ext"

require "objspace"
require "open3"
require "rbconfig"

class TestRegressions < Minitest::Test
  def test_core_ext_temporary_strings_do_not_leak_pools_after_gc
    force_full_gc
    before = ObjectSpace.each_object(StringView::Pool).count

    create_transient_core_ext_views(50)

    force_full_gc
    after = ObjectSpace.each_object(StringView::Pool).count

    assert_equal(
      before,
      after,
      "temporary strings should not leave cached pools behind after GC",
    )
  end

  def test_pool_reset_invalidates_single_byte_cache_for_reused_views
    backing = ("abc" + "é").freeze
    pool = StringView::Pool.new(backing)

    ascii = pool.view(0, 3)
    assert_equal(3, ascii.length)

    pool.reset!
    multibyte = pool.view(3, 2)

    assert_equal("é", multibyte.to_s)
    assert_equal(1, multibyte.length)
    refute_predicate(multibyte, :ascii_only?)
    assert_equal("é", multibyte[0].to_s)
  end

  def test_pool_reset_invalidates_single_byte_cache_for_invalid_utf8_views
    backing = "abc\xFF\xFE".b.force_encoding(Encoding::UTF_8).freeze
    pool = StringView::Pool.new(backing)

    ascii = pool.view(0, 3)
    assert_equal(3, ascii.length)

    pool.reset!
    invalid = pool.view(3, 2)

    refute_predicate(invalid, :valid_encoding?)
    assert_equal(backing.byteslice(3, 2).chr.bytes, invalid.chr.to_s.bytes)
  end

  def test_pool_reset_invalidates_stride_index_before_reuse
    stdout, stderr, status = ruby_capture(<<~RUBY)
      require "string_view"

      prefix = "🎉" * 129
      suffix = "é" * 129
      backing = (prefix + suffix).freeze

      pool = StringView::Pool.new(backing)
      pool.view(0, prefix.bytesize)[128, 1]

      pool.reset!
      reused = pool.view(prefix.bytesize, suffix.bytesize)
      slice = reused[128, 1]

      puts [slice.bytesize, slice.length, slice.to_s.bytes.join(",")].join("|")
    RUBY

    assert(
      status.success?,
      "reusing a pooled view after building a stride index should not crash or error\n#{stderr}",
    )
    assert_equal("2|1|195,169", stdout.strip)
  end

  def test_pooled_views_cannot_be_reset_directly
    pool = StringView::Pool.new("hello".freeze)
    view = pool.view(0, 5)

    error = assert_raises(RuntimeError) do
      view.reset!("world".freeze, 0, 5)
    end

    assert_match(/pooled StringView/i, error.message)
  end

  def test_incompatible_encoding_methods_match_string
    str = "é".encode("UTF-8").freeze
    other = "é".encode("ISO-8859-1").freeze
    sv = StringView.new(str)

    [:start_with?, :end_with?, :include?, :index, :delete_prefix, :delete_suffix].each do |method|
      assert_raises(Encoding::CompatibilityError) { str.public_send(method, other) }
      assert_raises(Encoding::CompatibilityError, "#{method} should match String") do
        sv.public_send(method, other)
      end
    end
  end

  def test_incompatible_encoding_search_methods_match_string
    str = "é".encode("UTF-8").freeze
    other = "é".encode("ISO-8859-1").freeze
    sv = StringView.new(str)

    [:rindex, :byteindex, :byterindex].each do |method|
      assert_raises(Encoding::CompatibilityError) { str.public_send(method, other) }
      assert_raises(Encoding::CompatibilityError, "#{method} should match String") do
        sv.public_send(method, other)
      end
    end

    assert_raises(Encoding::CompatibilityError) { str[other] }
    assert_raises(Encoding::CompatibilityError, "[] with String should match String") do
      sv[other]
    end
  end

  def test_mid_codepoint_slice_matches_string_byteslice_behavior
    str = "é".freeze
    expected = str.byteslice(1, 1)
    sv = StringView.new(str, 1, 1)

    assert_equal(expected.bytes, sv.to_s.bytes)
    assert_equal(expected.valid_encoding?, sv.valid_encoding?)
    assert_equal(expected.length, sv.length)
    assert_equal(expected.chr.bytes, sv.chr.to_s.bytes)
    assert_equal(expected[0].bytes, sv[0].to_s.bytes)
  end

  private

  def create_transient_core_ext_views(count)
    count.times do |i|
      str = +"transient-#{i}"
      str.view(0, 1)
    end
  end

  def force_full_gc
    3.times { GC.start }
  end

  def ruby_capture(code)
    Open3.capture3(
      RbConfig.ruby,
      "-I#{File.expand_path("../lib", __dir__)}",
      "-e",
      code,
    )
  end
end
