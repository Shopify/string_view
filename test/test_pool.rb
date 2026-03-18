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
    @backing = "Hello, World! This is a test buffer for pool allocation.".freeze
    @pool = StringView::Pool.new(@backing)
  end

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  def test_new
    pool = StringView::Pool.new("hello")
    assert_instance_of(StringView::Pool, pool)
  end

  def test_new_freezes_backing
    str = +"mutable"
    StringView::Pool.new(str)
    assert_predicate(str, :frozen?)
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
      assert_equal(expected, v.to_s,
        "view #{i} should be #{expected.inspect}, got #{v.to_s.inspect}")
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
    buffer = "name=Alice\nage=30\ncity=Toronto\nlang=Ruby\n".freeze
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
      pool.reset!  # reuse views for next iteration
    end

    assert_equal([
      ["name", "Alice"],
      ["age", "30"],
      ["city", "Toronto"],
      ["lang", "Ruby"],
    ], results)
  end

  def test_parser_loop_zero_alloc_steady_state
    # After the first iteration, the pool has enough views.
    # Every subsequent iteration allocates ZERO objects.
    buffer = "name=Alice\nage=30\ncity=Toronto\n".freeze
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
    assert_equal(0, per_iter,
      "Steady-state parse loop should allocate 0 objects per iteration, got #{per_iter}")
  end

  def test_parser_multiple_passes_same_pool
    # Pool survives across multiple complete passes over the buffer
    buffer = "a=1\nb=2\nc=3\n".freeze
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

      assert_equal([["a", "1"], ["b", "2"], ["c", "3"]], pairs,
        "Pass #{pass} should parse correctly")
    end
  end

  # ---------------------------------------------------------------------------
  # Views are proper StringViews — full API works
  # ---------------------------------------------------------------------------

  def test_view_supports_string_view_operations
    v = @pool.view(0, 13) # "Hello, World!"
    assert_equal(13, v.bytesize)
    assert_equal(13, v.length)
    assert(v.include?("World"))
    assert(v.start_with?("Hello"))
    assert(v.end_with?("!"))
    assert_equal(72, v.getbyte(0)) # 'H' = 72
  end

  def test_view_is_frozen
    v = @pool.view(0, 5)
    assert_predicate(v, :frozen?)
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
    pool = StringView::Pool.new(+"hello world")
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

    assert_equal(0, per_call.round,
      "Pool.view should allocate 0 objects per call when pre-warmed, " \
      "got #{per_call.round} (#{pool_allocs} total over #{n} calls)")
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

    assert_equal(1, per_call,
      "StringView.new should allocate 1 object per call, got #{per_call}")
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
    assert_includes([32, 33], growth,
      "Growth should allocate ~32 new views in one batch, got #{growth}")
    assert_equal(64, pool.capacity)
  end
end
