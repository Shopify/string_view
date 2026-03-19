# frozen_string_literal: true

require "test_helper"

#
# This test ensures that every public String instance method is accounted for
# in StringView — either explicitly implemented, deliberately rejected (bang
# methods raise FrozenError), or consciously listed as not-yet-implemented
# (handled by method_missing → NotImplementedError).
#
# When Ruby adds new String methods, this test will fail, forcing a conscious
# decision about whether to implement them natively on StringView.
#
class TestStringMethodCoverage < Minitest::Test
  # Methods that StringView implements natively in C or delegates via shared string.
  IMPLEMENTED = [
    :ascii_only?,
    :bytes,
    :byteindex,
    :byterindex,
    :bytesize,
    :byteslice,
    :capitalize,
    :center,
    :chars,
    :chomp,
    :chop,
    :chr,
    :count,
    :delete,
    :delete_prefix,
    :delete_suffix,
    :downcase,
    :each_byte,
    :each_char,
    :empty?,
    :encode,
    :encoding,
    :end_with?,
    :eql?,

    :getbyte,
    :gsub,
    :hash,
    :hex,
    :include?,
    :index,
    :length,
    :ljust,
    :lstrip,
    :match,
    :match?,
    :oct,
    :ord,
    :reverse,
    :rindex,
    :rjust,
    :rstrip,
    :scan,
    :scrub,
    :size,
    :slice,
    :split,
    :squeeze,
    :start_with?,
    :strip,
    :sub,
    :swapcase,
    :to_f,
    :to_i,
    :to_s,
    :tr,
    :tr_s,
    :unicode_normalize,
    :unpack1,
    :upcase,
    :valid_encoding?,
  ].freeze

  # These are registered as methods on StringView (via rb_define_method)
  # but are not standard String methods — they are StringView-specific.
  STRINGVIEW_SPECIFIC = [
    :materialize,
    :reset!,
  ].freeze

  # Operators and special methods implemented on StringView.
  OPERATORS = [
    :==,
    :<=>,
    :=~,
    :[],
    :%,
    :+,
    :*,
  ].freeze

  # Bang methods that raise FrozenError — StringView is immutable.
  FROZEN_BANG_METHODS = [
    :capitalize!,
    :chomp!,
    :chop!,
    :delete!,
    :delete_prefix!,
    :delete_suffix!,
    :downcase!,
    :gsub!,
    :lstrip!,
    :replace,
    :reverse!,
    :rstrip!,
    :slice!,
    :squeeze!,
    :strip!,
    :sub!,
    :swapcase!,
    :tr!,
    :upcase!,
  ].freeze

  # String methods that are intentionally NOT implemented on StringView.
  # These go through method_missing and raise NotImplementedError.
  # Each entry has a comment explaining why it's excluded.
  #
  # When Ruby adds a new String method, it will NOT appear in any of these
  # lists, causing test_all_string_methods_accounted_for to fail. That
  # forces you to either implement it or add it here with a reason.
  NOT_IMPLEMENTED = [
    :+@,
    :-@,
    :<<,
    :[]=,
    :append_as_bytes,
    :b,
    :bytesplice,
    :casecmp,
    :casecmp?,
    :clear,
    :codepoints,
    :concat,
    :crypt,
    :dedup,
    :dump,
    :each_codepoint,
    :each_grapheme_cluster,
    :each_line,
    :encode!,
    :force_encoding,
    :grapheme_clusters,
    :insert,
    :intern,
    :lines,
    :next,
    :next!,
    :partition,
    :prepend,
    :rpartition,
    :scrub!,
    :setbyte,
    :succ,
    :succ!,
    :sum,
    :to_c,
    :to_r,
    :to_str,
    :to_sym,
    :tr_s!,
    :undump,
    :unicode_normalize!,
    :unicode_normalized?,
    :unpack,
    :upto,
  ].freeze

  # -------------------------------------------------------------------
  # The main coverage test
  # -------------------------------------------------------------------

  def test_all_string_methods_accounted_for
    # All public methods on String that aren't from Object/Kernel/Comparable
    # Exclude methods added by StringView::CoreExt (our own monkeypatch)
    string_methods = String.instance_methods - Object.instance_methods - Comparable.instance_methods -
      StringView::CoreExt.instance_methods

    accounted_for = IMPLEMENTED + OPERATORS + FROZEN_BANG_METHODS + NOT_IMPLEMENTED

    unaccounted = string_methods - accounted_for
    assert_empty(
      unaccounted,
      "String methods not accounted for in StringView: #{unaccounted.sort.inspect}\n" \
        "Add each to IMPLEMENTED, FROZEN_BANG_METHODS, or NOT_IMPLEMENTED with a reason.",
    )
  end

  def test_no_phantom_methods_in_lists
    # Make sure we haven't listed methods that don't exist on String at all.
    # Some methods in our lists may only exist in newer Ruby versions (e.g.
    # append_as_bytes in 3.4+, dedup in 4.0+). That's OK — they're listed
    # for forward compatibility. We only flag methods that have been removed.
    all_string_methods = String.instance_methods
    all_listed = IMPLEMENTED + OPERATORS + FROZEN_BANG_METHODS + NOT_IMPLEMENTED

    # Filter to only methods that don't exist on String AND are not
    # known to be version-dependent additions.
    version_dependent = [
      :append_as_bytes, # 3.4+
      :dedup,           # 4.0+
    ]
    phantoms = all_listed - all_string_methods - STRINGVIEW_SPECIFIC - version_dependent

    assert_empty(
      phantoms,
      "Methods listed in coverage arrays that don't exist on String: #{phantoms.sort.inspect}\n" \
        "These may have been removed from Ruby. Clean up the lists.",
    )
  end

  # -------------------------------------------------------------------
  # Verify each category behaves correctly
  # -------------------------------------------------------------------

  def test_implemented_methods_respond
    sv = StringView.new("hello")
    IMPLEMENTED.each do |method|
      assert_respond_to(sv, method, "StringView should respond to ##{method}")
    end
  end

  def test_operators_respond
    sv = StringView.new("hello")
    OPERATORS.each do |method|
      assert_respond_to(sv, method, "StringView should respond to ##{method}")
    end
  end

  def test_frozen_bang_methods_raise_frozen_error
    sv = StringView.new("hello world")
    FROZEN_BANG_METHODS.each do |method|
      assert_raises(FrozenError, "StringView##{method} should raise FrozenError") do
        # Most bang methods need at least one argument
        case method
        when :replace, :insert, :prepend, :concat
          sv.public_send(method, "x")
        when :tr!, :tr_s!
          sv.public_send(method, "a", "b")
        when :gsub!, :sub!
          sv.public_send(method, "o", "0")
        when :chomp!
          sv.public_send(method, "\n")
        when :delete!, :delete_prefix!, :delete_suffix!
          sv.public_send(method, "l")
        when :squeeze!
          sv.public_send(method)
        when :[]=
          sv.public_send(method, 0, "x")
        when :slice!
          sv.public_send(method, 0)
        else
          sv.public_send(method)
        end
      end
    end
  end

  def test_not_implemented_methods_raise_not_implemented_error
    sv = StringView.new("hello")

    # These should raise NotImplementedError via method_missing.
    # Skip methods that are private on StringView (to_str), and methods
    # that don't exist on String in this Ruby version.
    skipped = [:to_str]

    (NOT_IMPLEMENTED - skipped).select { |m| String.method_defined?(m) }.each do |method|
      assert_raises(
        NotImplementedError,
        "StringView##{method} should raise NotImplementedError",
      ) do
        # Provide enough args to avoid ArgumentError before NotImplementedError
        case method
        when :casecmp, :casecmp?, :delete_prefix, :delete_prefix!, :delete_suffix, :delete_suffix!,
             :concat, :<<, :prepend, :insert, :force_encoding, :append_as_bytes
          sv.public_send(method, "x")
        when :upto
          sv.public_send(method, "z")
        when :[]=, :bytesplice, :setbyte
          sv.public_send(method, 0, "x")
        when :encode!
          sv.public_send(method, "UTF-8")
        when :unpack
          sv.public_send(method, "C*")
        when :unicode_normalize!, :unicode_normalized?
          sv.public_send(method, :nfc)
        else
          sv.public_send(method)
        end
      end
    end
  end

  def test_to_str_is_private
    sv = StringView.new("hello")
    # to_str exists but is private — not visible via respond_to?
    refute_respond_to(sv, :to_str)
    # But it works internally for coercion
    assert_equal(0, /hello/ =~ sv)
  end
end
