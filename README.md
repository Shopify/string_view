# StringView

A zero-copy, read-only view into a Ruby String, implemented as a C extension. StringView avoids allocating and copying bytes when slicing strings, making it significantly faster and more memory-efficient than `String#[]` for inner slices — especially on large buffers.

Think of it like C++'s `std::string_view` or Rust's `&str`: a lightweight window into an existing string's bytes.

## How it works

A `StringView` wraps a frozen Ruby String (the "backing") and stores a byte offset and length. Slicing a `StringView` returns a new `StringView` pointing into the same backing — no bytes are ever copied.

```ruby
buf = "Hello, world! This is a large buffer.".freeze
sv = StringView.new(buf)

# Slicing returns a new StringView — zero copy, O(1)
chunk = sv[7, 6]    # => #<StringView "world!">
chunk.to_s          # => "world!"
chunk.class         # => StringView
```

### Three-tier design

StringView methods are organized into three tiers based on their allocation behavior:

| Tier | Strategy | Returns | Allocations |
|------|----------|---------|-------------|
| **Tier 1** | Native C, zero-copy | Primitives | **0** |
| **Tier 2** | New view into same backing | `StringView` | **1 object** (no byte copy) |
| **Tier 3** | Delegate to String | `String` | **1 String** (result only) |

**Tier 1 — Zero-copy reads** (no allocations):
`bytesize`, `length`, `empty?`, `encoding`, `ascii_only?`, `include?`, `start_with?`, `end_with?`, `index`, `rindex`, `getbyte`, `byteindex`, `byterindex`, `each_byte`, `each_char`, `bytes`, `chars`, `match`, `match?`, `=~`, `to_i`, `to_f`, `hex`, `oct`, `==`, `<=>`, `eql?`, `hash`

**Tier 2 — Slicing returns StringView** (one object, zero byte copy):
`[]`, `slice`, `byteslice`

**Tier 3 — Transform via delegation** (one String for the result, no intermediate copy):
`upcase`, `downcase`, `capitalize`, `swapcase`, `strip`, `lstrip`, `rstrip`, `chomp`, `chop`, `reverse`, `squeeze`, `encode`, `gsub`, `sub`, `tr`, `split`, `scan`, `count`, `delete`, `center`, `ljust`, `rjust`, `%`, `+`, `*`, `unpack1`, `scrub`, `unicode_normalize`

### Design decisions

- **`to_str` is private.** Ruby's internal coercion protocol (`rb_check_string_type`) ignores method visibility, so StringView works seamlessly with `Regexp#=~`, string interpolation, and `String#+`. But `respond_to?(:to_str)` returns `false`, so code that explicitly checks for string-like objects won't treat StringView as a drop-in String replacement. When coercion happens, it returns a frozen shared string (zero-copy for heap-allocated backings).
- **All bang methods raise `FrozenError`.** StringView is immutable — `upcase!`, `gsub!`, `slice!`, etc. all raise immediately.
- **`method_missing` is a safety net.** Any String method not yet implemented natively raises `NotImplementedError` with a message telling you to call `.to_s.method_name(...)` explicitly. No silent fallback.

## Performance

### Where StringView is faster

StringView's primary advantage is **inner slicing** — extracting a substring from the middle of a large string. CRuby's `String#[]` must copy the bytes (except for tail slices), while StringView just adjusts an offset and length.

**Inner slice creation** (Ruby 4.0.2, YJIT, 1MB ASCII backing):

| Slice size | String | StringView | Speedup |
|------------|--------|------------|---------|
| 1 KB | 5.98M i/s | 22.4M i/s | **3.75x faster** |
| 10 KB | 1.74M i/s | 21.2M i/s | **12.2x faster** |
| 100 KB | 555K i/s | 21.5M i/s | **38.8x faster** |
| 500 KB | 131K i/s | 21.6M i/s | **165x faster** |

StringView slice creation is **constant time** (~45ns) regardless of slice size, while String scales linearly with the number of bytes copied.

**Combined: inner slice then operate** (the real-world pattern):

| Operation | String | StringView | Speedup |
|-----------|--------|------------|---------|
| slice + `start_with?` | 126K i/s | 18.9M i/s | **151x faster** |
| slice + `include?` (500KB) | 6.97K i/s | 7.37K i/s | 1.06x faster |
| 50 inner slices | 60.1K i/s | 396K i/s | **6.6x faster** |

**UTF-8 character-indexed slicing** (YJIT, 1.2M-char / 2.8MB UTF-8 string, stride index pre-built):

| Character offset | String | StringView | Speedup |
|------------------|--------|------------|---------|
| 100 | 0.029s | 0.021s | **1.4x faster** |
| 1,000 | 0.048s | 0.024s | **2x faster** |
| 10,000 | 0.144s | 0.020s | **7x faster** |
| 100,000 | 1.12s | 0.008s | **134x faster** |
| 500,000 | 5.25s | 0.007s | **743x faster** |
| 1,000,000 | 10.35s | 0.015s | **698x faster** |

StringView builds a stride index on first character-indexed access, making subsequent lookups O(1). String must scan from the beginning every time (O(n)).

**UTF-8 character counting** (`length` on multibyte strings):
- First call: **2.8x faster** than String (SIMD-accelerated via [simdutf](https://github.com/simdutf/simdutf))
- Subsequent calls: **100x faster** (cached)

**Memory** (1,000 inner slices of 10KB each from a 1MB string):
- String: **10 MB** (each slice copies its bytes)
- StringView: **224 KB** (each slice is a small embedded struct)
- **45x less memory**

**Reads on pre-existing slices:**

| Operation | String | StringView | Ratio |
|-----------|--------|------------|-------|
| `start_with?` | 40.0M i/s | 48.9M i/s | **1.22x faster** |
| `include?` (500KB) | 7.2K i/s | 7.2K i/s | same |

### Where String is faster

For simple accessor methods on pre-existing objects, String has a small advantage because its internal macros (`RSTRING_LEN`, etc.) are inlined by the compiler, while StringView goes through the TypedData API:

| Operation | String | StringView | Overhead |
|-----------|--------|------------|----------|
| `bytesize` | 67.4M i/s | 60.7M i/s | 1.11x slower |
| `getbyte` | 62.2M i/s | 57.3M i/s | same-ish (within error) |

This is the irreducible cost of being a C extension type rather than a built-in. In practice, the difference is ~5ns per call.

**Tail slices** (slices that extend to the end of the string) are already zero-copy in CRuby via shared strings, so StringView provides no advantage there.

**Small string slices** (below ~23 bytes) use CRuby's embedded string optimization, which is already very fast. StringView's per-object overhead is comparable.

### When to use StringView

StringView is most beneficial when you:

- Parse large buffers (HTTP bodies, log files, serialized data) by extracting many substrings
- Repeatedly slice into the middle of large strings
- Work with large UTF-8 text and need character-indexed access
- Want to reduce memory pressure from retained string slices
- Need to pass around "windows" into a string without copying

StringView is less beneficial when you:

- Work with small strings (< 1KB) where copy cost is negligible
- Only need tail slices (CRuby already optimizes these)
- Primarily call simple accessors (`bytesize`, `getbyte`) on pre-existing slices

## Installation

Add to your Gemfile:

```ruby
gem "string_view"
```

Or install directly:

```bash
gem install string_view
```

The gem includes a C extension that compiles during installation. It requires Ruby 3.3+ and a C99/C++17 compiler. Ruby 3.3 is needed for `RUBY_TYPED_EMBEDDABLE` (struct embedding in the Ruby object) and `RTYPEDDATA_GET_DATA` (fast struct access).

## Usage

### Basic usage

```ruby
require "string_view"

# Create from a String (freezes the backing automatically)
sv = StringView.new("Hello, world!")

# Slicing returns StringView — zero copy
greeting = sv[0, 5]        # => StringView "Hello"
name = sv[7, 5]            # => StringView "world"

# Chain slices — all share the same backing
first = greeting[0, 1]     # => StringView "H"

# Materialize when you need a real String
str = sv.to_s              # => "Hello, world!" (new String)

# Read-only operations work directly
sv.include?("world")       # => true
sv.start_with?("Hello")    # => true
sv.length                  # => 13
sv.bytesize                # => 13

# Transforms return String (not StringView)
sv.upcase                  # => "HELLO, WORLD!" (String)
sv.split(", ")             # => ["Hello", "world!"] (Array of Strings)
```

### Parsing a large buffer

```ruby
# Simulate a large HTTP response or log chunk
buffer = File.read("large_file.txt")
sv = StringView.new(buffer)

# Extract fields without copying the entire buffer
header = sv[0, 1024]                    # First 1KB — zero copy
body = sv[1024, sv.bytesize - 1024]     # Rest — zero copy

# Search within a region
body.include?("ERROR")                  # Searches directly, no copy
body.match?(/\d{4}-\d{2}-\d{2}/)       # Regex on the view
```

### Reusing a view with `reset!`

```ruby
sv = StringView.new("initial content")

# Re-point at a different backing string
new_data = "different content"
sv.reset!(new_data, 0, new_data.bytesize)
sv.to_s  # => "different content"
```

## Internals

### Struct layout

Each StringView is a small C struct embedded directly in the Ruby object (via `RUBY_TYPED_EMBEDDABLE`):

```
StringView object (no separate heap allocation)
├── backing: VALUE     — frozen String (strong GC reference)
├── base: const char*  — cached RSTRING_PTR(backing)
├── enc: rb_encoding*  — cached encoding
├── offset: long       — byte offset into backing
├── length: long       — byte length of this view
├── charlen: long      — cached character count (-1 = not computed)
├── single_byte: int   — cached flag: 1=ASCII/binary, 0=multibyte
└── stride_idx: ptr    — lazily-built char→byte index (UTF-8 only)
```

### UTF-8 acceleration

For UTF-8 strings with actual multibyte content, StringView uses two techniques:

1. **SIMD character counting** via [simdutf](https://github.com/simdutf/simdutf) — counts UTF-8 characters at billions of bytes per second using NEON (ARM) or SSE/AVX (x86).

2. **Stride index** — on first character-indexed access, builds a lookup table mapping every 128th character to its byte offset. Subsequent character→byte conversions are O(1): one table lookup + at most 128 bytes of scalar scan.

### Compilation

The extension is compiled with `-O3` and uses `__attribute__((always_inline))` on hot paths, `RTYPEDDATA_GET_DATA` for fast struct access (skipping type checks), and `FL_SET_RAW` for freeze (bypassing method dispatch).

## Development

```bash
git clone https://github.com/Shopify/string_view
cd string_view
bundle install
bundle exec rake compile
bundle exec rake test
```

Run benchmarks:

```bash
bundle exec rake compile
ruby --yjit -Ilib benchmark/bench.rb
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

simdutf is included under the [MIT License](https://github.com/simdutf/simdutf/blob/master/LICENSE-MIT) (also available under Apache 2.0). See [LICENSE-simdutf.txt](LICENSE-simdutf.txt) for the full text.

## Code of Conduct

Everyone interacting in the StringView project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/Shopify/string_view/blob/main/CODE_OF_CONDUCT.md).
