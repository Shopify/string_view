# Autoresearch: StringView Performance

## Objective
Optimize StringView C extension throughput across all operation types:
inner slice creation, accessor methods on pre-existing slices (bytesize,
getbyte, start_with?), and combined slice-then-operate patterns. The
benchmark compares StringView against CRuby's built-in String on a 1MB
ASCII backing string using YJIT.

## Metrics
- **Primary**: `composite` (geometric mean of all SV i/s values, higher is better)
- **Secondary**: Individual ratios (SV/String) — `slice_500k_ratio`, `bytesize_ratio`,
  `getbyte_ratio`, `start_with_ratio`, `slice_start_with_ratio`, `multi_slice_ratio`.
  Ratios > 1.0 mean SV wins.

## How to Run
`./autoresearch.sh` — compiles, runs tests, outputs `METRIC name=number` lines.
Takes ~10-15 seconds per run.

## Files in Scope
- `ext/string_view/string_view.c` — the entire C extension. All perf-relevant code is here.
- `ext/string_view/extconf.rb` — compiler flags.

## Off Limits
- `test/test_string_view.rb` — tests must pass but don't change them.
- `lib/string_view.rb` — Ruby-side glue, method_missing. Not on the hot path.
- `benchmark/bench.rb` — the full benchmark suite. Not used by autoresearch.sh.

## Constraints
- Tests must pass: `ruby -Ilib -Itest test/test_string_view.rb`
- No new gem dependencies.
- Must compile with `-std=c99 -Wall -Wextra`.
- The TypedData API is required by Ruby — can't bypass it.

## Architecture Notes
StringView wraps a `{VALUE backing, long offset, long length}` struct via
Ruby's TypedData API. The backing is a frozen String, strongly marked by
the GC. Key hot paths:

1. **sv_get_struct**: `TypedData_Get_Struct` — unwraps the C struct from the Ruby object.
   Called on every method entry. This is the irreducible overhead vs. String's inline macros.

2. **sv_new_from_backing**: `TypedData_Make_Struct` + `RB_OBJ_WRITE` + `rb_obj_freeze`.
   Called for every `[]`/slice. The allocation cost is O(1) but the constant is high.

3. **sv_single_byte_optimizable**: Fast path for ASCII content — avoids O(n) character
   scanning. Checks `ENC_CODERANGE_7BIT` first, falls back to byte scan for unknown coderange.

4. **sv_as_shared_str**: Creates a `rb_str_subseq` shared string for delegation. Used by
   index, rindex, match, to_i, and all Tier 3 methods. Each call allocates one String.

## What's Been Tried
- **Baseline**: Current state after removing `sv_backing_or_raise`. Accessor methods are
  ~1.5-2.2x slower than String due to TypedData overhead. Inner slicing is 13-62x faster
  than String (zero-copy vs. memcpy).
