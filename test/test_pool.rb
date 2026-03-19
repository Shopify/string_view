# frozen_string_literal: true

require "test_helper"

#
# StringView::Pool — amortized-allocation view factory for a single backing string.
#
# == The problem
#
# When parsing a large buffer (HTTP response, log file, CSV, serialized data),
# you often extract dozens or hundreds of substrings per parse call. Each
# `StringView.new(backing, offset, length)` allocates one Ruby object (~250ns).
# In a hot loop processing thousands of messages, this adds up:
#
#   10,000 messages × 20 fields × 250ns = 50ms just in allocation overhead
#
# == The solution
#
# `StringView::Pool` pre-allocates a batch of StringView objects tied to a
# single backing string. Calling `pool.view(offset, length)` returns one of
# these pre-built views with its offset/length set — no Ruby allocation at all
# (~11ns). When the pool is exhausted, it grows exponentially (32 → 64 → 128…).
#
# Between parse iterations, call `pool.reset!` to rewind the cursor. The
# same pre-allocated views get repointed to new byte ranges on the next pass.
#
# == Typical usage: looped parser
#
#   pool = StringView::Pool.new(buffer)
#
#   buffer.each_line do |line|
#     # Parse fields from the line — each .view() is ~11ns, zero allocation
#     timestamp = pool.view(line_offset, 19)
#     level     = pool.view(line_offset + 20, 4)
#     message   = pool.view(line_offset + 25, msg_len)
#
#     process(timestamp, level, message)
#
#     pool.reset!  # rewind cursor — views get reused next iteration
#   end
#
# == Important: view lifetime after reset!
#
# After `pool.reset!`, previously returned views are still valid Ruby objects
# (the GC tracks them), but their offset/length WILL be overwritten by the
# next `.view()` call that reuses that slot. If you need a view to survive
# past a reset, either:
#   - Call `.to_s` to materialize it into a String before resetting
#   - Use `StringView.new(backing, offset, length)` for long-lived views
#   - Don't call reset! (let the pool grow — views stay valid forever)
#
# == GC safety
#
# Every view in the pool is a real Ruby object managed by the GC. The pool
# holds them in a Ruby Array (GC-visible). Each view holds a strong reference
# to the backing string. No tricks, no unsafe pointers, no finalizers.
# Compaction-safe via rb_gc_mark_movable.
#
# == Performance
#
#   StringView.new:          ~250ns/op   (3M ops/s)
#   Pool.view (grow path):   ~170ns/op   (6M ops/s)    — 1.5x faster
#   Pool.view (reuse path):   ~11ns/op  (90M ops/s)    — 29x faster
#
class TestStringViewPool < Minitest::Test
  def setup
    @backing = -"Hello, World! This is a test buffer for pool allocation."
    @pool = StringView::Pool.new(@backing)
  end

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  def test_new
    pool = StringView::Pool.new("hello")
    assert_instance_of(StringView::Pool, pool)
  end

  def test_new_requires_frozen_backing
    str = +"mutable"
    assert_raises(FrozenError) { StringView::Pool.new(str) }
  end

  def test_new_requires_string
    assert_raises(TypeError) { StringView::Pool.new(42) }
    assert_raises(TypeError) { StringView::Pool.new(nil) }
  end

  def test_initial_capacity
    assert_equal(32, @pool.capacity)
  end

  def test_initial_size
    assert_equal(0, @pool.size)
  end

  def test_backing
    assert_same(@backing, @pool.backing)
  end

  # ---------------------------------------------------------------------------
  # view(byte_offset, byte_length) → StringView
  #
  # Returns a pre-allocated StringView pointing at the given byte range.
  # This is the hot path — when views are available, it's just two long
  # writes and an array read. No Ruby object allocation.
  # ---------------------------------------------------------------------------

  def test_view_returns_string_view
    v = @pool.view(0, 5)
    assert_instance_of(StringView, v)
  end

  def test_view_correct_content
    v = @pool.view(0, 5)
    assert_equal("Hello", v.to_s)
  end

  def test_view_with_offset
    v = @pool.view(7, 6)
    assert_equal("World!", v.to_s)
  end

  def test_view_increments_size
    @pool.view(0, 5)
    assert_equal(1, @pool.size)
    @pool.view(0, 5)
    assert_equal(2, @pool.size)
  end

  def test_view_bounds_check
    assert_raises(ArgumentError) { @pool.view(0, 10_000) }
    assert_raises(ArgumentError) { @pool.view(-1, 5) }
    assert_raises(ArgumentError) { @pool.view(0, -1) }
  end

  def test_view_zero_length
    v = @pool.view(10, 0)
    assert_predicate(v, :empty?)
    assert_equal("", v.to_s)
  end

  def test_view_full_backing
    v = @pool.view(0, @backing.bytesize)
    assert_equal(@backing, v.to_s)
  end

  def test_multiple_views_independent
    v1 = @pool.view(0, 5)
    v2 = @pool.view(7, 6)
    assert_equal("Hello", v1.to_s)
    assert_equal("World!", v2.to_s)
    refute_same(v1, v2)
  end

  # ---------------------------------------------------------------------------
  # Exponential growth
  #
  # The pool starts with 32 pre-allocated views. When exhausted, it doubles:
  # 32 → 64 → 128 → 256 → ... All new views in a growth batch are allocated
  # consecutively (good cache locality) and pre-initialized with the backing
  # string's metadata.
  # ---------------------------------------------------------------------------

  def test_grows_past_initial_capacity
    33.times { @pool.view(0, 1) }
    assert_equal(33, @pool.size)
    assert_equal(64, @pool.capacity)
  end

  def test_grows_exponentially
    65.times { @pool.view(0, 1) }
    assert_equal(65, @pool.size)
    assert_equal(128, @pool.capacity)
  end

  def test_views_correct_after_growth
    views = 40.times.map { |i| @pool.view(i % @backing.bytesize, 1) }
    views.each_with_index do |v, i|
      expected = @backing[i % @backing.bytesize]
      assert_equal(
        expected,
        v.to_s,
        "view #{i} should be #{expected.inspect}, got #{v.to_s.inspect}",
      )
    end
  end

  # ---------------------------------------------------------------------------
  # reset!
  #
  # Rewinds the pool cursor to 0. The next .view() call reuses slot 0,
  # then slot 1, etc. The pre-allocated StringView objects are the same
  # Ruby objects — only their offset/length fields get overwritten.
  #
  # This is the key to the "looped parser" pattern: each parse iteration
  # calls reset! at the start (or end), so the pool never grows beyond
  # the high-water mark of views needed per iteration.
  # ---------------------------------------------------------------------------

  def test_reset_resets_size
    10.times { @pool.view(0, 1) }
    assert_equal(10, @pool.size)
    @pool.reset!
    assert_equal(0, @pool.size)
  end

  def test_reset_preserves_capacity
    10.times { @pool.view(0, 1) }
    cap = @pool.capacity
    @pool.reset!
    assert_equal(cap, @pool.capacity)
  end

  def test_reset_returns_self
    result = @pool.reset!
    assert_same(@pool, result)
  end

  def test_views_work_after_reset
    @pool.view(0, 5)
    @pool.reset!
    v = @pool.view(7, 6)
    assert_equal("World!", v.to_s)
  end

  # ---------------------------------------------------------------------------
  # Parser loop pattern
  #
  # This is the primary use case. Imagine parsing a buffer that contains
  # multiple records (HTTP headers, CSV rows, log lines). Each iteration
  # extracts N fields as StringViews, processes them, then resets the pool.
  #
  # After the first iteration, the pool has enough capacity and every
  # subsequent .view() call is zero-allocation (~11ns).
  #
  #   pool = StringView::Pool.new(buffer)
  #
  #   records.each do |record_offset, record_length|
  #     name  = pool.view(record_offset,      name_len)
  #     value = pool.view(record_offset + sep, value_len)
  #     process(name, value)
  #     pool.reset!
  #   end
  #
  # ---------------------------------------------------------------------------

  def test_parser_loop_pattern
    # Simulate parsing "key=value" pairs from a buffer
    buffer = "name=Alice\nage=30\ncity=Toronto\nlang=Ruby\n"
    pool = StringView::Pool.new(buffer)

    # Parse all key=value pairs in a loop
    results = []
    pos = 0
    while pos < buffer.bytesize
      nl = buffer.index("\n", pos) || buffer.bytesize
      eq = buffer.index("=", pos)
      break unless eq && eq < nl

      key   = pool.view(pos, eq - pos)
      value = pool.view(eq + 1, nl - eq - 1)

      # Views work like strings — all read operations available
      results << [key.to_s, value.to_s]

      pos = nl + 1
      pool.reset! # reuse views for next iteration
    end

    assert_equal(
      [
        ["name", "Alice"],
        ["age", "30"],
        ["city", "Toronto"],
        ["lang", "Ruby"],
      ],
      results,
    )
  end

  def test_parser_loop_zero_alloc_steady_state
    # After the first iteration, the pool has enough views.
    # Every subsequent iteration allocates ZERO objects.
    buffer = "name=Alice\nage=30\ncity=Toronto\n"
    pool = StringView::Pool.new(buffer)

    # First pass: warms up the pool
    parse = lambda do
      pos = 0
      while pos < buffer.bytesize
        nl = buffer.index("\n", pos) || buffer.bytesize
        eq = buffer.index("=", pos)
        break unless eq && eq < nl

        _key   = pool.view(pos, eq - pos)
        _value = pool.view(eq + 1, nl - eq - 1)
        pos = nl + 1
      end
      pool.reset!
    end

    # Warm up
    10.times { parse.call }

    # Measure: should be zero allocations per iteration
    n = 1000
    GC.disable
    before = GC.stat(:total_allocated_objects)
    n.times { parse.call }
    after = GC.stat(:total_allocated_objects)
    GC.enable

    per_iter = ((after - before).to_f / n).round
    assert_equal(
      0,
      per_iter,
      "Steady-state parse loop should allocate 0 objects per iteration, got #{per_iter}",
    )
  end

  def test_parser_multiple_passes_same_pool
    # Pool survives across multiple complete passes over the buffer
    buffer = "a=1\nb=2\nc=3\n"
    pool = StringView::Pool.new(buffer)

    3.times do |pass|
      pairs = []
      pos = 0
      while pos < buffer.bytesize
        nl = buffer.index("\n", pos) || buffer.bytesize
        eq = buffer.index("=", pos)
        break unless eq && eq < nl

        key   = pool.view(pos, eq - pos)
        value = pool.view(eq + 1, nl - eq - 1)
        pairs << [key.to_s, value.to_s]
        pos = nl + 1
      end
      pool.reset!

      assert_equal(
        [["a", "1"], ["b", "2"], ["c", "3"]],
        pairs,
        "Pass #{pass} should parse correctly",
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Views are proper StringViews — full API works
  # ---------------------------------------------------------------------------

  def test_view_supports_string_view_operations
    v = @pool.view(0, 13) # "Hello, World!"
    assert_equal(13, v.bytesize)
    assert_equal(13, v.length)
    assert_includes(v, "World")
    assert(v.start_with?("Hello"))
    assert(v.end_with?("!"))
    assert_equal(72, v.getbyte(0)) # 'H' = 72
  end

  def test_view_is_not_frozen
    v = @pool.view(0, 5)
    refute_predicate(v, :frozen?)
  end

  def test_view_comparison
    v = @pool.view(0, 5)
    assert_equal(v, "Hello")
    assert_equal(v, StringView.new("Hello"))
  end

  def test_view_slicing
    v = @pool.view(0, 13) # "Hello, World!"
    s = v[7, 5]
    assert_instance_of(StringView, s)
    assert_equal("World", s.to_s)
  end

  # ---------------------------------------------------------------------------
  # GC safety
  #
  # The pool and its views are all regular Ruby objects with proper GC
  # mark callbacks. The pool marks its backing string and views array.
  # Each view marks its backing string. Compaction is handled via
  # rb_gc_mark_movable + dcompact callbacks.
  # ---------------------------------------------------------------------------

  def test_pool_survives_gc
    pool = StringView::Pool.new("hello world")
    v = pool.view(0, 5)
    GC.start
    GC.start
    assert_equal("hello", v.to_s)
    assert_equal("hello world", pool.backing)
  end

  def test_views_survive_gc_without_pool_reference
    # Even if the pool is GC'd, the views keep the backing alive
    # via their own strong mark.
    v = StringView::Pool.new("hello world").view(0, 5)
    GC.start
    GC.start
    assert_equal("hello", v.to_s)
  end

  # ---------------------------------------------------------------------------
  # Allocation efficiency
  #
  # The whole point: after warm-up, pool.view() allocates ZERO Ruby objects.
  # Compare with StringView.new which allocates 1 per call.
  # ---------------------------------------------------------------------------

  def test_pool_view_zero_allocs_when_pre_warmed
    backing = ("x" * 1000).freeze
    pool = StringView::Pool.new(backing)

    # Pre-warm: grow pool, then reset twice to settle JIT
    1100.times { pool.view(0, 10) }
    pool.reset!
    1000.times { pool.view(0, 10) }
    pool.reset!

    n = 1000
    GC.disable
    before = GC.stat(:total_allocated_objects)
    n.times { pool.view(0, 10) }
    after = GC.stat(:total_allocated_objects)
    GC.enable
    per_call = (pool_allocs = after - before).to_f / n

    assert_equal(
      0,
      per_call.round,
      "Pool.view should allocate 0 objects per call when pre-warmed, " \
        "got #{per_call.round} (#{pool_allocs} total over #{n} calls)",
    )
  end

  def test_new_allocates_one_per_call
    backing = ("x" * 1000).freeze
    StringView.new(backing, 0, 10) # warm

    n = 1000
    GC.disable
    before = GC.stat(:total_allocated_objects)
    n.times { StringView.new(backing, 0, 10) }
    after = GC.stat(:total_allocated_objects)
    GC.enable
    per_call = ((after - before).to_f / n).round

    assert_equal(
      1,
      per_call,
      "StringView.new should allocate 1 object per call, got #{per_call}",
    )
  end

  def test_pool_growth_allocates_batch
    backing = ("x" * 1000).freeze
    pool = StringView::Pool.new(backing)

    # Exhaust the initial 32
    32.times { pool.view(0, 10) }
    assert_equal(32, pool.capacity)

    # 33rd triggers doubling — allocates ~32 new views in one batch
    GC.disable
    before = GC.stat(:total_allocated_objects)
    pool.view(0, 10)
    after = GC.stat(:total_allocated_objects)
    GC.enable
    growth = after - before
    # 32 new StringView objects, plus possibly 1 for Array buffer resize
    assert_includes(
      [32, 33],
      growth,
      "Growth should allocate ~32 new views in one batch, got #{growth}",
    )
    assert_equal(64, pool.capacity)
  end

  # ---------------------------------------------------------------------------
  # Construction edge cases
  # ---------------------------------------------------------------------------

  def test_new_with_empty_string
    pool = StringView::Pool.new("")
    assert_equal(0, pool.backing.bytesize)
    v = pool.view(0, 0)
    assert_predicate(v, :empty?)
  end

  def test_new_with_frozen_string
    str = "already frozen"
    pool = StringView::Pool.new(str)
    assert_same(str, pool.backing)
  end

  def test_new_with_binary_string
    str = "\x00\x01\xFF\xFE".b.freeze
    pool = StringView::Pool.new(str)
    v = pool.view(0, 4)
    assert_equal(Encoding::ASCII_8BIT, v.encoding)
    assert_equal(str, v.to_s)
  end

  def test_new_with_large_string
    str = ("a" * 1_000_000).freeze
    pool = StringView::Pool.new(str)
    v = pool.view(500_000, 1000)
    assert_equal("a" * 1000, v.to_s)
  end

  # ---------------------------------------------------------------------------
  # view() — boundary and edge cases
  # ---------------------------------------------------------------------------

  def test_view_at_start
    v = @pool.view(0, 1)
    assert_equal("H", v.to_s)
  end

  def test_view_at_end
    len = @backing.bytesize
    v = @pool.view(len - 1, 1)
    assert_equal(".", v.to_s)
  end

  def test_view_exact_end_boundary
    len = @backing.bytesize
    v = @pool.view(len, 0)
    assert_predicate(v, :empty?)
  end

  def test_view_overflow_at_end
    len = @backing.bytesize
    assert_raises(ArgumentError) { @pool.view(len, 1) }
  end

  def test_view_single_byte
    v = @pool.view(0, 1)
    assert_equal(1, v.bytesize)
    assert_equal(1, v.length)
  end

  def test_view_adjacent_non_overlapping
    v1 = @pool.view(0, 5)   # "Hello"
    v2 = @pool.view(5, 2)   # ", "
    v3 = @pool.view(7, 6)   # "World!"
    assert_equal("Hello", v1.to_s)
    assert_equal(", ", v2.to_s)
    assert_equal("World!", v3.to_s)
  end

  def test_view_overlapping_ranges
    v1 = @pool.view(0, 8)   # "Hello, W"
    v2 = @pool.view(5, 8)   # ", World!"
    assert_equal("Hello, W", v1.to_s)
    assert_equal(", World!", v2.to_s)
  end

  def test_view_same_range_twice
    v1 = @pool.view(0, 5)
    v2 = @pool.view(0, 5)
    assert_equal(v1.to_s, v2.to_s)
    refute_same(v1, v2) # different StringView objects
  end

  def test_view_many_zero_length
    10.times { @pool.view(0, 0) }
    assert_equal(10, @pool.size)
  end

  # ---------------------------------------------------------------------------
  # Bounds checking — thorough
  # ---------------------------------------------------------------------------

  def test_view_negative_offset
    assert_raises(ArgumentError) { @pool.view(-1, 1) }
  end

  def test_view_negative_length
    assert_raises(ArgumentError) { @pool.view(0, -1) }
  end

  def test_view_negative_both
    assert_raises(ArgumentError) { @pool.view(-1, -1) }
  end

  def test_view_offset_past_end
    assert_raises(ArgumentError) { @pool.view(@backing.bytesize + 1, 0) }
  end

  def test_view_length_overflows_backing
    assert_raises(ArgumentError) { @pool.view(0, @backing.bytesize + 1) }
  end

  def test_view_offset_plus_length_overflows
    assert_raises(ArgumentError) { @pool.view(@backing.bytesize - 1, 2) }
  end

  def test_view_large_offset_and_length_no_integer_overflow
    # With a naive `off + len > backing_len` check, two large positive longs
    # can wrap around to a small (or negative) value and bypass the guard.
    # LONG_MAX for offset, 1 for length: naive `off + len` wraps to LONG_MIN
    assert_raises(ArgumentError) { @pool.view((2**63) - 1, 1) }
  end

  # ---------------------------------------------------------------------------
  # Exponential growth — detailed
  # ---------------------------------------------------------------------------

  def test_growth_sequence
    pool = StringView::Pool.new(@backing)
    assert_equal(32, pool.capacity)

    32.times { pool.view(0, 1) }
    assert_equal(32, pool.capacity) # not yet grown

    pool.view(0, 1) # 33rd — triggers growth
    assert_equal(64, pool.capacity)

    (64 - 33).times { pool.view(0, 1) }
    assert_equal(64, pool.capacity) # not yet grown

    pool.view(0, 1) # 65th — triggers growth
    assert_equal(128, pool.capacity)
  end

  def test_growth_many_doublings
    pool = StringView::Pool.new(@backing)
    # Fill to trigger several doublings: 32 → 64 → 128 → 256 → 512
    500.times { pool.view(0, 1) }
    assert_equal(512, pool.capacity)
    assert_equal(500, pool.size)
  end

  def test_growth_caps_at_4096_per_batch
    pool = StringView::Pool.new(@backing)
    # Grow past the doubling threshold: 32→64→128→256→512→1024→2048→4096→8192
    # At capacity 4096, the next grow adds 4096 (capped), not 8192 (doubled).
    8192.times { pool.view(0, 1) }
    assert_equal(8192, pool.capacity)

    # One more triggers a capped grow of 4096, not a doubling to 16384
    pool.view(0, 1)
    assert_equal(8192 + 4096, pool.capacity)
  end

  def test_all_views_valid_after_multiple_growths
    pool = StringView::Pool.new("abcdefghij")
    views = 200.times.map { |i| pool.view(i % 10, 1) }
    views.each_with_index do |v, i|
      expected = "abcdefghij"[i % 10]
      assert_equal(expected, v.to_s, "view #{i}")
    end
  end

  # ---------------------------------------------------------------------------
  # reset! — detailed lifecycle
  # ---------------------------------------------------------------------------

  def test_reset_on_fresh_pool
    @pool.reset!
    assert_equal(0, @pool.size)
    v = @pool.view(0, 5)
    assert_equal("Hello", v.to_s)
  end

  def test_reset_multiple_times
    @pool.view(0, 5)
    @pool.reset!
    @pool.reset!
    @pool.reset!
    assert_equal(0, @pool.size)
    v = @pool.view(0, 5)
    assert_equal("Hello", v.to_s)
  end

  def test_reset_then_grow
    # Fill initial capacity, reset, then exceed it
    32.times { @pool.view(0, 1) }
    @pool.reset!
    40.times { @pool.view(0, 1) }
    assert_equal(40, @pool.size)
    assert_equal(64, @pool.capacity)
  end

  def test_reset_does_not_shrink_capacity
    100.times { @pool.view(0, 1) }
    assert_equal(128, @pool.capacity)
    @pool.reset!
    assert_equal(128, @pool.capacity) # never shrinks
    5.times { @pool.view(0, 1) }
    assert_equal(128, @pool.capacity) # still same
  end

  def test_view_overwrite_after_reset
    # Verify that reset! causes slot reuse by checking object identity
    v1 = @pool.view(0, 5) # slot 0 → "Hello"
    @pool.reset!
    v2 = @pool.view(7, 6) # slot 0 again → "World!"

    # Same Ruby object, different content (slot 0 was repointed)
    assert_same(v1, v2)
    assert_equal("World!", v2.to_s)
    # v1 and v2 are the same object, so v1 also shows the new content
    assert_equal("World!", v1.to_s)
  end

  def test_materialize_before_reset_preserves_value
    v1 = @pool.view(0, 5)
    saved = v1.to_s # materialize to a String
    @pool.reset!
    _v2 = @pool.view(7, 6) # overwrites slot 0

    # The materialized String is independent
    assert_equal("Hello", saved)
    # The view now points at the new range
    assert_equal("World!", v1.to_s)
  end

  # ---------------------------------------------------------------------------
  # Multibyte / UTF-8
  # ---------------------------------------------------------------------------

  def test_utf8_backing
    str = "café résumé naïve"
    pool = StringView::Pool.new(str)

    # "café" is 5 bytes (c=1, a=1, f=1, é=2)
    v = pool.view(0, 5)
    assert_equal("café", v.to_s)
    assert_equal(4, v.length) # 4 characters
    assert_equal(5, v.bytesize) # 5 bytes
  end

  def test_utf8_view_at_multibyte_boundary
    str = "日本語テスト" # 6 chars × 3 bytes = 18 bytes
    pool = StringView::Pool.new(str)

    v1 = pool.view(0, 3)   # "日"
    v2 = pool.view(3, 3)   # "本"
    v3 = pool.view(6, 3)   # "語"
    assert_equal("日", v1.to_s)
    assert_equal("本", v2.to_s)
    assert_equal("語", v3.to_s)
  end

  def test_utf8_view_all_characters
    str = "🎉🎊🎈" # 3 emoji × 4 bytes = 12 bytes
    pool = StringView::Pool.new(str)

    v1 = pool.view(0, 4)
    v2 = pool.view(4, 4)
    v3 = pool.view(8, 4)
    assert_equal("🎉", v1.to_s)
    assert_equal("🎊", v2.to_s)
    assert_equal("🎈", v3.to_s)
  end

  def test_utf8_view_mixed_width
    str = "aé日🎉b"
    pool = StringView::Pool.new(str)
    # a=1, é=2, 日=3, 🎉=4, b=1 → total 11 bytes
    assert_equal(11, str.bytesize)

    v = pool.view(0, 11)
    assert_equal(5, v.length)
    assert_equal(11, v.bytesize)
  end

  # ---------------------------------------------------------------------------
  # View interop with StringView operations
  # ---------------------------------------------------------------------------

  def test_view_include
    v = @pool.view(0, 13) # "Hello, World!"
    assert_includes(v, "World")
    refute_includes(v, "xyz")
  end

  def test_view_start_with
    v = @pool.view(0, 13)
    assert(v.start_with?("Hello"))
    refute(v.start_with?("World"))
  end

  def test_view_end_with
    v = @pool.view(0, 13)
    assert(v.end_with?("!"))
    refute(v.end_with?("Hello"))
  end

  def test_view_getbyte
    v = @pool.view(0, 5) # "Hello"
    assert_equal(72, v.getbyte(0))  # H
    assert_equal(111, v.getbyte(4)) # o
    assert_nil(v.getbyte(5))
    assert_equal(111, v.getbyte(-1)) # o (negative index)
  end

  def test_view_empty
    v = @pool.view(0, 0)
    assert_predicate(v, :empty?)
    v2 = @pool.view(0, 1)
    refute_predicate(v2, :empty?)
  end

  def test_view_ascii_only
    ascii_backing = "hello"
    pool = StringView::Pool.new(ascii_backing)
    v = pool.view(0, 5)
    assert_predicate(v, :ascii_only?)
  end

  def test_view_encoding
    v = @pool.view(0, 5)
    assert_equal(Encoding::UTF_8, v.encoding)
  end

  def test_view_to_i
    buffer = "42 hello 99"
    pool = StringView::Pool.new(buffer)
    v = pool.view(0, 2)
    assert_equal(42, v.to_i)
  end

  def test_view_to_f
    buffer = "3.14 hello"
    pool = StringView::Pool.new(buffer)
    v = pool.view(0, 4)
    assert_in_delta(3.14, v.to_f)
  end

  def test_view_eq_string
    v = @pool.view(0, 5)
    assert_equal(v, "Hello")
    refute_equal(v, "World")
  end

  def test_view_eq_string_view
    v = @pool.view(0, 5)
    sv = StringView.new("Hello")
    assert_equal(v, sv)
  end

  def test_view_eq_another_pool_view
    pool2 = StringView::Pool.new("Hello world")
    v1 = @pool.view(0, 5)
    v2 = pool2.view(0, 5)
    assert_equal(v1, v2)
  end

  def test_view_cmp
    pool = StringView::Pool.new("abc def ghi")
    v1 = pool.view(0, 3)  # "abc"
    v2 = pool.view(4, 3)  # "def"
    assert_equal(-1, v1 <=> v2)
    assert_equal(1, v2 <=> v1)
    assert_equal(0, v1 <=> "abc")
  end

  def test_view_hash
    v = @pool.view(0, 5)
    sv = StringView.new(@backing, 0, 5)
    assert_equal(sv.hash, v.hash)
  end

  def test_view_as_hash_key
    h = {}
    v = @pool.view(0, 5)
    h[v] = :found
    sv = StringView.new("Hello")
    assert_equal(:found, h[sv])
  end

  def test_view_each_byte
    v = @pool.view(0, 3) # "Hel"
    bytes = []
    v.each_byte { |b| bytes << b }
    assert_equal([72, 101, 108], bytes)
  end

  def test_view_bytes
    v = @pool.view(0, 3)
    assert_equal([72, 101, 108], v.bytes)
  end

  def test_view_slicing_returns_string_view
    v = @pool.view(0, 13)
    s = v[0, 5]
    assert_instance_of(StringView, s)
    assert_equal("Hello", s.to_s)
  end

  def test_view_byteslice
    v = @pool.view(0, 13)
    s = v.byteslice(7, 5)
    assert_instance_of(StringView, s)
    assert_equal("World", s.to_s)
  end

  def test_view_upcase_delegates
    v = @pool.view(0, 5)
    assert_equal("HELLO", v.upcase)
  end

  def test_view_downcase_delegates
    v = @pool.view(0, 5)
    assert_equal("hello", v.downcase)
  end

  def test_view_split_delegates
    buffer = "a,b,c"
    pool = StringView::Pool.new(buffer)
    v = pool.view(0, 5)
    assert_equal(["a", "b", "c"], v.split(","))
  end

  # ---------------------------------------------------------------------------
  # Stress tests
  # ---------------------------------------------------------------------------

  def test_many_views_without_reset
    pool = StringView::Pool.new(("x" * 100).freeze)
    views = 10_000.times.map { pool.view(0, 1) }
    assert_equal(10_000, pool.size)
    # Capacity should have grown: 32 → 64 → ... → 16384
    assert_operator(pool.capacity, :>=, 10_000)
    # All views should still be valid
    views.each { |v| assert_equal("x", v.to_s) }
  end

  def test_rapid_reset_cycle
    pool = StringView::Pool.new(@backing)
    1000.times do
      5.times { pool.view(0, 1) }
      pool.reset!
    end
    # Pool should have stabilized at initial capacity
    assert_equal(32, pool.capacity)
    assert_equal(0, pool.size)
  end

  def test_alternating_small_and_large_iterations
    pool = StringView::Pool.new(("x" * 100).freeze)

    # First iteration: 5 views
    5.times { pool.view(0, 1) }
    pool.reset!

    # Second iteration: 50 views (forces growth)
    50.times { pool.view(0, 1) }
    pool.reset!

    # Third iteration: 5 views again (reuses, no growth)
    # Warm this exact path once more before measuring
    5.times { pool.view(0, 1) }
    pool.reset!

    n = 100
    GC.disable
    before = GC.stat(:total_allocated_objects)
    n.times do
      5.times { pool.view(0, 1) }
      pool.reset!
    end
    after = GC.stat(:total_allocated_objects)
    GC.enable

    per_iter = ((after - before).to_f / n).round
    assert_equal(
      0,
      per_iter,
      "Small iteration after large one should allocate 0 objects per iter, got #{per_iter}",
    )
  end

  # ---------------------------------------------------------------------------
  # GC safety — extended
  # ---------------------------------------------------------------------------

  def test_gc_during_pool_use
    pool = StringView::Pool.new("test buffer for gc")
    views = []
    10.times do
      views << pool.view(0, 4)
      GC.start if views.size == 5 # GC in the middle
    end
    views.each { |v| assert_equal("test", v.to_s) }
  end

  def test_pool_and_views_survive_compaction
    pool = StringView::Pool.new("compact me")
    v = pool.view(0, 7)
    GC.auto_compact = true
    GC.start
    GC.start
    assert_equal("compact", v.to_s)
    assert_equal("compact me", pool.backing)
  ensure
    GC.auto_compact = false
  end

  def test_multiple_pools_same_backing
    backing = "shared backing"
    pool1 = StringView::Pool.new(backing)
    pool2 = StringView::Pool.new(backing)

    v1 = pool1.view(0, 6) # "shared"
    v2 = pool2.view(7, 7) # "backing"
    assert_equal("shared", v1.to_s)
    assert_equal("backing", v2.to_s)
  end

  def test_multiple_pools_different_backings
    pool1 = StringView::Pool.new("hello world")
    pool2 = StringView::Pool.new("goodbye world")

    v1 = pool1.view(0, 5)
    v2 = pool2.view(0, 7)
    assert_equal("hello", v1.to_s)
    assert_equal("goodbye", v2.to_s)
  end

  # ---------------------------------------------------------------------------
  # Parser patterns — real-world-ish scenarios
  # ---------------------------------------------------------------------------

  def test_csv_parser_pattern
    csv = "name,age,city\nAlice,30,Toronto\nBob,25,London\n"
    pool = StringView::Pool.new(csv)

    rows = []
    pos = 0
    while pos < csv.bytesize
      nl = csv.index("\n", pos) || csv.bytesize
      fields = []

      # Parse comma-separated fields
      while pos < nl
        comma = csv.index(",", pos)
        field_end = comma && comma < nl ? comma : nl
        fields << pool.view(pos, field_end - pos).to_s
        pos = field_end + 1
      end
      rows << fields
      pos = nl + 1
      pool.reset!
    end

    assert_equal(
      [
        ["name", "age", "city"],
        ["Alice", "30", "Toronto"],
        ["Bob", "25", "London"],
      ],
      rows,
    )
  end

  def test_http_header_parser_pattern
    headers = "Content-Type: text/html\r\nContent-Length: 42\r\nHost: example.com\r\n\r\n"
    pool = StringView::Pool.new(headers)

    parsed = {}
    pos = 0
    while pos < headers.bytesize
      crlf = headers.index("\r\n", pos)
      break if crlf.nil? || crlf == pos # empty line = end of headers

      colon = headers.index(": ", pos)
      break unless colon && colon < crlf

      key   = pool.view(pos, colon - pos)
      value = pool.view(colon + 2, crlf - colon - 2)
      parsed[key.to_s] = value.to_s

      pos = crlf + 2
      pool.reset!
    end

    assert_equal(
      {
        "Content-Type" => "text/html",
        "Content-Length" => "42",
        "Host" => "example.com",
      },
      parsed,
    )
  end

  def test_log_line_parser_pattern
    # Fixed-width format: [timestamp] LEVEL message
    # Level is always 5 chars (padded), message starts at offset 28
    log = "[2024-01-15 10:30:00] INFO  Application started\n" \
      "[2024-01-15 10:30:01] WARN  Disk usage high\n" \
      "[2024-01-15 10:30:02] ERROR Connection refused\n"
    log.freeze
    pool = StringView::Pool.new(log)

    entries = []
    pos = 0
    while pos < log.bytesize
      nl = log.index("\n", pos) || log.bytesize
      break if nl - pos < 28

      ts    = pool.view(pos + 1, 19)            # "2024-01-15 10:30:00"
      level = pool.view(pos + 22, 5).to_s.strip # "INFO" or "ERROR" (strip padding)
      msg   = pool.view(pos + 28, nl - pos - 28)
      entries << { ts: ts.to_s, level: level, msg: msg.to_s }

      pos = nl + 1
      pool.reset!
    end

    assert_equal(3, entries.length)
    assert_equal("2024-01-15 10:30:00", entries[0][:ts])
    assert_equal("INFO", entries[0][:level])
    assert_equal("Application started", entries[0][:msg])
    assert_equal("ERROR", entries[2][:level])
    assert_equal("Connection refused", entries[2][:msg])
  end

  def test_repeated_field_extraction
    # Simulate extracting the same field positions from many records
    # (e.g., fixed-width format)
    record = "John    Doe     30Toronto   \n" \
      "Jane    Smith   25London    \n" \
      "Bob     Brown   35Berlin    \n"
    record.freeze
    pool = StringView::Pool.new(record)

    people = []
    pos = 0
    while pos + 28 <= record.bytesize
      first = pool.view(pos, 8).to_s.strip
      last  = pool.view(pos + 8, 8).to_s.strip
      age   = pool.view(pos + 16, 2)
      city  = pool.view(pos + 18, 10).to_s.strip
      people << { first: first, last: last, age: age.to_i, city: city }
      pos += 29 # 28 chars + newline
      pool.reset!
    end

    assert_equal(3, people.length)
    assert_equal("John", people[0][:first])
    assert_equal("Doe", people[0][:last])
    assert_equal(30, people[0][:age])
    assert_equal("Toronto", people[0][:city])
    assert_equal("Bob", people[2][:first])
    assert_equal(35, people[2][:age])
  end
end
