#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/re.h"
#include "simdutf_wrapper.h"

#define SV_LIKELY(x)   __builtin_expect(!!(x), 1)
#define SV_UNLIKELY(x) __builtin_expect(!!(x), 0)

#ifdef __GNUC__
#define SV_INLINE static inline __attribute__((always_inline))
#else
#define SV_INLINE static inline
#endif

/* ========================================================================= */
/* Struct & TypedData                                                        */
/* ========================================================================= */

typedef struct {
    VALUE  backing;     /* frozen String that owns the bytes */
    const char *base;   /* cached RSTRING_PTR(backing) — avoids indirection */
    rb_encoding *enc;   /* cached encoding — avoids rb_enc_get per call */
    long   offset;      /* byte offset into backing */
    long   length;      /* byte length of this view */
    long   charlen;     /* cached character count; -1 = not yet computed */
    int    single_byte; /* cached: 1 if char==byte (ASCII/single-byte enc), 0 if multibyte, -1 unknown */
} string_view_t;

static VALUE cStringView;

/*
 * GC callbacks.
 *
 * We use rb_gc_mark_movable (strong mark) so the view keeps the backing
 * alive. This is the fast path — no WeakMap, no rb_funcall overhead.
 *
 * The intended ownership model is still that the *caller* keeps the
 * backing alive (like std::string_view), but the GC enforces safety:
 * if the caller drops their reference, the view's strong mark prevents
 * a dangling pointer. When rb_gc_mark_weak becomes a public C API,
 * we can switch to true non-owning semantics with zero API changes.
 */
static void sv_mark(void *ptr) {
    string_view_t *sv = (string_view_t *)ptr;
    if (sv->backing != Qnil) {
        rb_gc_mark_movable(sv->backing);
    }
}

static void sv_compact(void *ptr) {
    string_view_t *sv = (string_view_t *)ptr;
    if (sv->backing != Qnil) {
        sv->backing = rb_gc_location(sv->backing);
        sv->base = RSTRING_PTR(sv->backing);
    }
}

static size_t sv_memsize(const void *ptr) {
    return sizeof(string_view_t);
}

static const rb_data_type_t string_view_type = {
    "StringView",
    { sv_mark, RUBY_TYPED_DEFAULT_FREE, sv_memsize, sv_compact },
    0, 0,
    RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_FROZEN_SHAREABLE | RUBY_TYPED_EMBEDDABLE
};

/* Forward declarations */
static int sv_compute_single_byte(VALUE backing, rb_encoding *enc);

/* ========================================================================= */
/* Internal helpers                                                          */
/* ========================================================================= */

SV_INLINE string_view_t *sv_get_struct(VALUE self) {
    return (string_view_t *)RTYPEDDATA_GET_DATA(self);
}

/* Pointer to the start of this view's bytes */
SV_INLINE const char *sv_ptr(string_view_t *sv) {
    return sv->base + sv->offset;
}

/* encoding of the backing string */
SV_INLINE rb_encoding *sv_enc(string_view_t *sv) {
    return sv->enc;
}

/*
 * Create a shared String that aliases the backing's heap buffer.
 * The result is frozen to prevent mutation through the alias.
 */
static VALUE sv_as_shared_str(string_view_t *sv) {
    VALUE shared = rb_str_subseq(sv->backing, sv->offset, sv->length);
    rb_obj_freeze(shared);
    return shared;
}

/* Allocate a new StringView from a parent that already has cached base/enc */
SV_INLINE VALUE sv_new_from_parent(string_view_t *parent, long offset, long length) {
    string_view_t *sv;
    VALUE obj = TypedData_Make_Struct(cStringView, string_view_t,
                                     &string_view_type, sv);
    RB_OBJ_WRITE(obj, &sv->backing, parent->backing);
    sv->base        = parent->base;
    sv->enc         = parent->enc;
    sv->offset      = offset;
    sv->length      = length;
    sv->single_byte = parent->single_byte;
    sv->charlen     = -1;
    FL_SET_RAW(obj, FL_FREEZE);
    return obj;
}

/* Allocate a new StringView VALUE pointing into a raw backing string */
SV_INLINE VALUE sv_new_from_backing(VALUE backing, long offset, long length) {
    string_view_t *sv;
    VALUE obj = TypedData_Make_Struct(cStringView, string_view_t,
                                     &string_view_type, sv);
    rb_encoding *enc = rb_enc_get(backing);
    RB_OBJ_WRITE(obj, &sv->backing, backing);
    sv->base        = RSTRING_PTR(backing);
    sv->enc         = enc;
    sv->offset      = offset;
    sv->length      = length;
    sv->single_byte = sv_compute_single_byte(backing, enc);
    sv->charlen     = -1;
    FL_SET_RAW(obj, FL_FREEZE);
    return obj;
}

/* ========================================================================= */
/* Construction                                                              */
/* ========================================================================= */

static VALUE sv_alloc(VALUE klass) {
    string_view_t *sv;
    VALUE obj = TypedData_Make_Struct(klass, string_view_t,
                                     &string_view_type, sv);
    sv->backing     = Qnil;
    sv->base        = NULL;
    sv->enc         = NULL;
    sv->offset      = 0;
    sv->length      = 0;
    sv->single_byte = -1;
    sv->charlen     = -1;
    return obj;
}

/*
 * StringView.new(string)
 * StringView.new(string, byte_offset, byte_length)
 */
static VALUE sv_initialize(int argc, VALUE *argv, VALUE self) {
    VALUE str, voffset, vlength;
    long offset, length;

    rb_scan_args(argc, argv, "12", &str, &voffset, &vlength);

    if (!RB_TYPE_P(str, T_STRING)) {
        rb_raise(rb_eTypeError,
                 "no implicit conversion of %s into String",
                 rb_obj_classname(str));
    }

    rb_str_freeze(str);

    long backing_len = RSTRING_LEN(str);

    if (NIL_P(voffset)) {
        offset = 0;
        length = backing_len;
    } else {
        offset = NUM2LONG(voffset);
        length = NUM2LONG(vlength);

        if (offset < 0 || length < 0 || offset + length > backing_len) {
            rb_raise(rb_eArgError,
                     "offset %ld, length %ld out of range for string of bytesize %ld",
                     offset, length, backing_len);
        }
    }

    string_view_t *sv = sv_get_struct(self);
    rb_encoding *enc = rb_enc_get(str);
    RB_OBJ_WRITE(self, &sv->backing, str);
    sv->base        = RSTRING_PTR(str);
    sv->enc         = enc;
    sv->offset      = offset;
    sv->length      = length;
    sv->single_byte = sv_compute_single_byte(str, enc);
    sv->charlen     = -1;

    rb_obj_freeze(self);

    return self;
}

/* ========================================================================= */
/* to_s / materialize / inspect / reset!                                     */
/* ========================================================================= */

static VALUE sv_to_s(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    return rb_enc_str_new(sv_ptr(sv), sv->length, sv_enc(sv));
}

static VALUE sv_inspect(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE content = rb_enc_str_new(sv_ptr(sv), sv->length, sv_enc(sv));
    return rb_sprintf("#<StringView:%p \"%"PRIsVALUE"\" offset=%ld length=%ld>",
                      (void *)self, content, sv->offset, sv->length);
}

static VALUE sv_frozen_p(VALUE self) {
    return Qtrue;
}

/*
 * reset!(new_backing, byte_offset, byte_length) -> self
 */
static VALUE sv_reset(VALUE self, VALUE new_backing, VALUE voffset, VALUE vlength) {
    string_view_t *sv = sv_get_struct(self);

    if (!RB_TYPE_P(new_backing, T_STRING)) {
        rb_raise(rb_eTypeError,
                 "no implicit conversion of %s into String",
                 rb_obj_classname(new_backing));
    }

    rb_str_freeze(new_backing);

    long off = NUM2LONG(voffset);
    long len = NUM2LONG(vlength);
    long backing_len = RSTRING_LEN(new_backing);

    if (off < 0 || len < 0 || off + len > backing_len) {
        rb_raise(rb_eArgError,
                 "offset %ld, length %ld out of range for string of bytesize %ld",
                 off, len, backing_len);
    }

    rb_encoding *enc = rb_enc_get(new_backing);
    RB_OBJ_WRITE(self, &sv->backing, new_backing);
    sv->base        = RSTRING_PTR(new_backing);
    sv->enc         = enc;
    sv->offset      = off;
    sv->length      = len;
    sv->single_byte = sv_compute_single_byte(new_backing, enc);
    sv->charlen     = -1;

    return self;
}

/* ========================================================================= */
/* Tier 1: Structural                                                        */
/* ========================================================================= */

static VALUE sv_bytesize(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    return LONG2NUM(sv->length);
}

/* Forward: sv_char_count is defined in Tier 2 but needed here */
static long sv_char_count(string_view_t *sv);

static VALUE sv_length(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    return LONG2NUM(sv_char_count(sv));
}

static VALUE sv_empty_p(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    return sv->length == 0 ? Qtrue : Qfalse;
}

static VALUE sv_encoding(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    return rb_enc_from_encoding(sv_enc(sv));
}

static VALUE sv_ascii_only_p(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);
    long i;
    for (i = 0; i < sv->length; i++) {
        if ((unsigned char)p[i] > 127) return Qfalse;
    }
    return Qtrue;
}

/* ========================================================================= */
/* Tier 1: Searching                                                         */
/* ========================================================================= */

static VALUE sv_include_p(VALUE self, VALUE substr) {
    string_view_t *sv = sv_get_struct(self);
    StringValue(substr);
    const char *p = sv_ptr(sv);
    long slen = RSTRING_LEN(substr);
    if (slen == 0) return Qtrue;
    if (slen > sv->length) return Qfalse;

    long pos = rb_memsearch(RSTRING_PTR(substr), slen, p, sv->length, sv_enc(sv));
    return pos >= 0 && pos <= sv->length - slen ? Qtrue : Qfalse;
}

static VALUE sv_start_with_p(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);
    int i;

    for (i = 0; i < argc; i++) {
        VALUE prefix = argv[i];
        StringValue(prefix);
        long plen = RSTRING_LEN(prefix);
        if (plen > sv->length) continue;
        if (memcmp(p, RSTRING_PTR(prefix), plen) == 0) return Qtrue;
    }
    return Qfalse;
}

static VALUE sv_end_with_p(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);
    int i;

    for (i = 0; i < argc; i++) {
        VALUE suffix = argv[i];
        StringValue(suffix);
        long slen = RSTRING_LEN(suffix);
        if (slen > sv->length) continue;
        if (memcmp(p + sv->length - slen, RSTRING_PTR(suffix), slen) == 0)
            return Qtrue;
    }
    return Qfalse;
}

static VALUE sv_index(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcallv(shared, rb_intern("index"), argc, argv);
}

static VALUE sv_rindex(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcallv(shared, rb_intern("rindex"), argc, argv);
}

static VALUE sv_getbyte(VALUE self, VALUE vidx) {
    string_view_t *sv = sv_get_struct(self);
    long idx = NUM2LONG(vidx);
    if (idx < 0) idx += sv->length;
    if (idx < 0 || idx >= sv->length) return Qnil;
    return INT2FIX((unsigned char)sv_ptr(sv)[idx]);
}

static VALUE sv_byteindex(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcallv(shared, rb_intern("byteindex"), argc, argv);
}

static VALUE sv_byterindex(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcallv(shared, rb_intern("byterindex"), argc, argv);
}

/* ========================================================================= */
/* Tier 1: Iteration                                                         */
/* ========================================================================= */

static VALUE sv_each_byte(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    RETURN_ENUMERATOR(self, 0, 0);
    const char *p = sv_ptr(sv);
    long i;
    for (i = 0; i < sv->length; i++) {
        rb_yield(INT2FIX((unsigned char)p[i]));
    }
    return self;
}

static VALUE sv_each_char(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    RETURN_ENUMERATOR(self, 0, 0);
    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv);
    const char *e = p + sv->length;
    while (p < e) {
        int clen = rb_enc_fast_mbclen(p, e, enc);
        rb_yield(rb_enc_str_new(p, clen, enc));
        p += clen;
    }
    return self;
}

static VALUE sv_bytes(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);
    VALUE ary = rb_ary_new_capa(sv->length);
    long i;
    for (i = 0; i < sv->length; i++) {
        rb_ary_push(ary, INT2FIX((unsigned char)p[i]));
    }
    return ary;
}

static VALUE sv_chars(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv);
    const char *e = p + sv->length;
    VALUE ary = rb_ary_new();
    while (p < e) {
        int clen = rb_enc_fast_mbclen(p, e, enc);
        rb_ary_push(ary, rb_enc_str_new(p, clen, enc));
        p += clen;
    }
    return ary;
}

/* ========================================================================= */
/* Tier 1: Pattern matching                                                  */
/* ========================================================================= */

static VALUE sv_match(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcallv(shared, rb_intern("match"), argc, argv);
}

static VALUE sv_match_p(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcallv(shared, rb_intern("match?"), argc, argv);
}

static VALUE sv_match_operator(VALUE self, VALUE pattern) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcall(shared, rb_intern("=~"), 1, pattern);
}

/* ========================================================================= */
/* Tier 1: Numeric conversions                                               */
/* ========================================================================= */

static VALUE sv_to_i(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcallv(shared, rb_intern("to_i"), argc, argv);
}

static VALUE sv_to_f(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcall(shared, rb_intern("to_f"), 0);
}

static VALUE sv_hex(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcall(shared, rb_intern("hex"), 0);
}

static VALUE sv_oct(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE shared = sv_as_shared_str(sv);
    return rb_funcall(shared, rb_intern("oct"), 0);
}

/* ========================================================================= */
/* Tier 1: Comparison                                                        */
/* ========================================================================= */

static VALUE sv_eq(VALUE self, VALUE other) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);

    /* Fast path: String is the most common comparison target */
    if (SV_LIKELY(RB_TYPE_P(other, T_STRING))) {
        if (sv->length != RSTRING_LEN(other)) return Qfalse;
        return memcmp(p, RSTRING_PTR(other), sv->length) == 0 ? Qtrue : Qfalse;
    }

    /* Check for StringView via class pointer (faster than rb_obj_is_kind_of) */
    if (rb_obj_class(other) == cStringView) {
        string_view_t *o = sv_get_struct(other);
        if (sv->length != o->length) return Qfalse;
        return memcmp(p, sv_ptr(o), sv->length) == 0 ? Qtrue : Qfalse;
    }

    return Qfalse;
}

static VALUE sv_cmp(VALUE self, VALUE other) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);
    const char *op;
    long olen;

    if (SV_LIKELY(RB_TYPE_P(other, T_STRING))) {
        op = RSTRING_PTR(other);
        olen = RSTRING_LEN(other);
    } else if (rb_obj_class(other) == cStringView) {
        string_view_t *o = sv_get_struct(other);
        op = sv_ptr(o);
        olen = o->length;
    } else {
        return Qnil;
    }

    long min = sv->length < olen ? sv->length : olen;
    int cmp = memcmp(p, op, min);
    if (cmp == 0) {
        if (sv->length < olen) cmp = -1;
        else if (sv->length > olen) cmp = 1;
    } else {
        cmp = cmp > 0 ? 1 : -1;
    }
    return INT2FIX(cmp);
}

static VALUE sv_eql_p(VALUE self, VALUE other) {
    if (rb_obj_class(other) != cStringView) return Qfalse;
    return sv_eq(self, other);
}

static VALUE sv_hash(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);
    st_index_t h = rb_memhash(p, sv->length);
    h ^= (st_index_t)rb_enc_get_index(sv->backing);
    return ST2FIX(h);
}

/* ========================================================================= */
/* Tier 2: Slicing — returns StringView                                      */
/* ========================================================================= */

/*
 * Returns true if this view's content is single-byte: either the encoding
 * has mbmaxlen==1 (e.g. ASCII, ISO-8859-*) or we can quickly determine
 * all bytes are ASCII (< 128) in a UTF-8 string via the backing string's
 * coderange.
 */
/*
 * Compute single-byte flag from encoding + coderange.
 * Called once at construction time and cached in sv->single_byte.
 */
static int sv_compute_single_byte(VALUE backing, rb_encoding *enc) {
    if (rb_enc_mbmaxlen(enc) == 1) return 1;
    int cr = ENC_CODERANGE(backing);
    if (cr == ENC_CODERANGE_7BIT) return 1;
    /* For VALID (known multibyte) we know it's not single-byte */
    if (cr == ENC_CODERANGE_VALID) return 0;
    /* UNKNOWN: we don't know yet — return -1 (will be resolved lazily) */
    return -1;
}

SV_INLINE int sv_single_byte_optimizable(string_view_t *sv) {
    int sb = sv->single_byte;
    if (SV_LIKELY(sb >= 0)) return sb;
    /* Resolve unknown coderange by scanning our slice */
    const char *p = sv_ptr(sv);
    long i;
    for (i = 0; i < sv->length; i++) {
        if (SV_UNLIKELY((unsigned char)p[i] > 127)) {
            sv->single_byte = 0;
            return 0;
        }
    }
    sv->single_byte = 1;
    return 1;
}

/* ---- UTF-8 optimized helpers ------------------------------------------- */

static rb_encoding *enc_utf8 = NULL;

SV_INLINE int sv_is_utf8(string_view_t *sv) {
    return sv->enc == enc_utf8;
}

/*
 * UTF-8 character count using simdutf — SIMD-accelerated (NEON/SSE/AVX).
 * Processes billions of characters per second on modern hardware.
 */
static long sv_utf8_char_count(const char *p, long len) {
    return (long)simdutf_count_utf8(p, (size_t)len);
}

/*
 * UTF-8 character byte length from the lead byte, via lookup table.
 * Assumes valid UTF-8 (which is guaranteed by Ruby's frozen backing).
 */
static const unsigned char utf8_char_len[256] = {
    /* 0x00-0x7F: ASCII, 1 byte */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    /* 0x80-0xBF: continuation bytes — shouldn't be lead bytes, treat as 1 */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    /* 0xC0-0xDF: 2-byte sequences */
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    /* 0xE0-0xEF: 3-byte sequences */
    3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,
    /* 0xF0-0xF7: 4-byte sequences */
    4,4,4,4,4,4,4,4,
    /* 0xF8-0xFF: invalid, treat as 1 */
    1,1,1,1,1,1,1,1
};

/*
 * Find the byte offset of the char_idx-th character in a UTF-8 string.
 * Uses a lookup table for branchless character width.
 */
static long sv_utf8_char_to_byte_offset(const char *p, long len, long char_idx) {
    const unsigned char *s = (const unsigned char *)p;
    const unsigned char *e = s + len;
    long chars = 0;

    while (s < e && chars < char_idx) {
        s += utf8_char_len[*s];
        chars++;
    }

    if (chars < char_idx) return -1;
    return (const char *)s - p;
}

/*
 * Count byte length for n characters starting at byte offset byte_off
 * in a UTF-8 string.
 */
static long sv_utf8_chars_to_bytes(const char *p, long len, long byte_off, long n) {
    const unsigned char *s = (const unsigned char *)p + byte_off;
    const unsigned char *e = (const unsigned char *)p + len;
    const unsigned char *start = s;
    long chars = 0;

    while (s < e && chars < n) {
        s += utf8_char_len[*s];
        chars++;
    }

    return (long)(s - start);
}

/* ---- Generic encoding helpers with UTF-8 fast paths -------------------- */

static long sv_char_to_byte_offset(string_view_t *sv, long char_idx) {
    if (sv_single_byte_optimizable(sv)) {
        return char_idx;
    }

    if (SV_LIKELY(sv_is_utf8(sv))) {
        return sv_utf8_char_to_byte_offset(sv_ptr(sv), sv->length, char_idx);
    }

    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv);
    const char *e = p + sv->length;
    const char *start = p;
    long i;

    for (i = 0; i < char_idx && p < e; i++) {
        p += rb_enc_fast_mbclen(p, e, enc);
    }

    if (i < char_idx) return -1;
    return p - start;
}

static long sv_char_count(string_view_t *sv) {
    /* Return cached value if available */
    if (SV_LIKELY(sv->charlen >= 0)) return sv->charlen;

    long count;
    if (sv_single_byte_optimizable(sv)) {
        count = sv->length;
    } else if (SV_LIKELY(sv_is_utf8(sv))) {
        count = sv_utf8_char_count(sv_ptr(sv), sv->length);
    } else {
        rb_encoding *enc = sv_enc(sv);
        const char *p = sv_ptr(sv);
        count = rb_enc_strlen(p, p + sv->length, enc);
    }

    sv->charlen = count;
    return count;
}

static long sv_chars_to_bytes(string_view_t *sv, long byte_off, long n) {
    if (sv_single_byte_optimizable(sv)) {
        long remaining = sv->length - byte_off;
        return n < remaining ? n : remaining;
    }

    if (SV_LIKELY(sv_is_utf8(sv))) {
        return sv_utf8_chars_to_bytes(sv_ptr(sv), sv->length, byte_off, n);
    }

    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv) + byte_off;
    const char *e = sv_ptr(sv) + sv->length;
    long i;
    const char *start = p;

    for (i = 0; i < n && p < e; i++) {
        p += rb_enc_fast_mbclen(p, e, enc);
    }
    return p - start;
}

static VALUE sv_aref(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE arg1, arg2;

    if (SV_UNLIKELY(argc < 1 || argc > 2)) {
        rb_error_arity(argc, 1, 2);
    }
    arg1 = argv[0];
    arg2 = (argc == 2) ? argv[1] : Qnil;

    if (argc == 2) {
        long idx = NUM2LONG(arg1);
        long len = NUM2LONG(arg2);

        if (SV_LIKELY(sv_single_byte_optimizable(sv))) {
            /* Fast path: char == byte for ASCII content */
            long total = sv->length;
            if (idx < 0) idx += total;
            if (SV_UNLIKELY(idx < 0 || idx > total || len < 0)) return Qnil;
            if (idx + len > total) len = total - idx;
            return sv_new_from_parent(sv,
                                       sv->offset + idx,
                                       len);
        }

        /* Multibyte path */
        if (len < 0) return Qnil;

        if (idx < 0) {
            /* Negative index: need total char count */
            long total_chars = sv_char_count(sv);
            idx += total_chars;
            if (idx < 0) return Qnil;
        }

        if (SV_LIKELY(sv_is_utf8(sv))) {
            /* UTF-8 combined single-pass: find byte_off for idx chars,
             * then continue scanning len more chars for byte_len */
            const unsigned char *s = (const unsigned char *)sv_ptr(sv);
            const unsigned char *e = s + sv->length;
            long chars = 0;

            /* Phase 1: skip idx characters to find byte_off */
            while (s < e && chars < idx) {
                s += utf8_char_len[*s];
                chars++;
            }
            if (chars < idx) return Qnil;

            const unsigned char *slice_start = s;

            /* Phase 2: skip len more characters to find byte_len */
            long counted = 0;
            while (s < e && counted < len) {
                s += utf8_char_len[*s];
                counted++;
            }

            return sv_new_from_parent(sv,
                                       sv->offset + (long)((const char *)slice_start - (const char *)sv_ptr(sv)),
                                       (long)(s - slice_start));
        }

        /* Generic multibyte fallback */
        long byte_off = sv_char_to_byte_offset(sv, idx);
        if (byte_off < 0) return Qnil;

        long byte_len = sv_chars_to_bytes(sv, byte_off, len);

        return sv_new_from_parent(sv,
                                   sv->offset + byte_off,
                                   byte_len);
    }

    if (rb_obj_is_kind_of(arg1, rb_cRange)) {
        long total_chars = sv_char_count(sv);
        long beg, len;
        int excl;
        VALUE rb_beg = rb_funcall(arg1, rb_intern("begin"), 0);
        VALUE rb_end = rb_funcall(arg1, rb_intern("end"), 0);
        excl = RTEST(rb_funcall(arg1, rb_intern("exclude_end?"), 0));

        beg = NIL_P(rb_beg) ? 0 : NUM2LONG(rb_beg);
        if (beg < 0) beg += total_chars;
        if (beg < 0) return Qnil;

        long e;
        if (NIL_P(rb_end)) {
            e = total_chars;
        } else {
            e = NUM2LONG(rb_end);
            if (e < 0) e += total_chars;
            if (!excl) e += 1;
        }
        if (e < beg) e = beg;
        len = e - beg;
        if (beg > total_chars) return Qnil;
        if (beg + len > total_chars) len = total_chars - beg;

        long byte_off = sv_char_to_byte_offset(sv, beg);
        long byte_len = sv_chars_to_bytes(sv, byte_off, len);

        return sv_new_from_parent(sv,
                                   sv->offset + byte_off,
                                   byte_len);
    }

    if (rb_obj_is_kind_of(arg1, rb_cRegexp)) {
        VALUE shared = sv_as_shared_str(sv);
        VALUE m = rb_funcall(arg1, rb_intern("match"), 1, shared);
        if (NIL_P(m)) return Qnil;

        VALUE matched = rb_funcall(m, rb_intern("[]"), 1, INT2FIX(0));
        long match_beg = NUM2LONG(rb_funcall(m, rb_intern("begin"), 1, INT2FIX(0)));

        long byte_off = sv_char_to_byte_offset(sv, match_beg);
        long byte_len = RSTRING_LEN(matched);

        return sv_new_from_parent(sv,
                                   sv->offset + byte_off,
                                   byte_len);
    }

    if (RB_TYPE_P(arg1, T_STRING)) {
        const char *p = sv_ptr(sv);
        long slen = RSTRING_LEN(arg1);
        if (slen == 0) {
            return sv_new_from_parent(sv, sv->offset, 0);
        }
        if (slen > sv->length) return Qnil;

        long pos = rb_memsearch(RSTRING_PTR(arg1), slen, p, sv->length, sv_enc(sv));
        if (pos < 0 || pos > sv->length - slen) return Qnil;

        return sv_new_from_parent(sv, sv->offset + pos, slen);
    }

    if (RB_INTEGER_TYPE_P(arg1)) {
        long char_idx = NUM2LONG(arg1);
        long total_chars = sv_char_count(sv);

        if (char_idx < 0) char_idx += total_chars;
        if (char_idx < 0 || char_idx >= total_chars) return Qnil;

        long byte_off = sv_char_to_byte_offset(sv, char_idx);
        if (byte_off < 0) return Qnil;

        long byte_len = sv_chars_to_bytes(sv, byte_off, 1);

        return sv_new_from_parent(sv,
                                   sv->offset + byte_off,
                                   byte_len);
    }

    rb_raise(rb_eTypeError, "no implicit conversion of %s into Integer",
             rb_obj_classname(arg1));
    return Qnil;
}

static VALUE sv_byteslice(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE arg1, arg2;

    if (SV_UNLIKELY(argc < 1 || argc > 2)) {
        rb_error_arity(argc, 1, 2);
    }
    arg1 = argv[0];
    arg2 = (argc == 2) ? argv[1] : Qnil;

    if (argc == 2) {
        long off = NUM2LONG(arg1);
        long len = NUM2LONG(arg2);

        if (off < 0) off += sv->length;
        if (off < 0 || off > sv->length) return Qnil;
        if (len < 0) return Qnil;
        if (off + len > sv->length) len = sv->length - off;

        return sv_new_from_parent(sv, sv->offset + off, len);
    }

    if (rb_obj_is_kind_of(arg1, rb_cRange)) {
        long beg, len;
        VALUE rb_beg = rb_funcall(arg1, rb_intern("begin"), 0);
        VALUE rb_end = rb_funcall(arg1, rb_intern("end"), 0);
        int excl = RTEST(rb_funcall(arg1, rb_intern("exclude_end?"), 0));

        beg = NIL_P(rb_beg) ? 0 : NUM2LONG(rb_beg);
        if (beg < 0) beg += sv->length;
        if (beg < 0) return Qnil;

        long e;
        if (NIL_P(rb_end)) {
            e = sv->length;
        } else {
            e = NUM2LONG(rb_end);
            if (e < 0) e += sv->length;
            if (!excl) e += 1;
        }
        if (e < beg) e = beg;
        len = e - beg;
        if (beg > sv->length) return Qnil;
        if (beg + len > sv->length) len = sv->length - beg;

        return sv_new_from_parent(sv, sv->offset + beg, len);
    }

    {
        long idx = NUM2LONG(arg1);
        if (idx < 0) idx += sv->length;
        if (idx < 0 || idx >= sv->length) return Qnil;
        return sv_new_from_parent(sv, sv->offset + idx, 1);
    }
}

/* ========================================================================= */
/* Tier 3: Transform delegation                                              */
/* ========================================================================= */

#define SV_DELEGATE_FUNCALL(cname, rbname)                              \
    static VALUE sv_##cname(int argc, VALUE *argv, VALUE self) {        \
        string_view_t *sv = sv_get_struct(self);                        \
        VALUE shared = sv_as_shared_str(sv);                            \
        return rb_funcallv(shared, rb_intern(rbname), argc, argv);      \
    }

SV_DELEGATE_FUNCALL(upcase,    "upcase")
SV_DELEGATE_FUNCALL(downcase,  "downcase")
SV_DELEGATE_FUNCALL(capitalize,"capitalize")
SV_DELEGATE_FUNCALL(swapcase,  "swapcase")
SV_DELEGATE_FUNCALL(strip,     "strip")
SV_DELEGATE_FUNCALL(lstrip,    "lstrip")
SV_DELEGATE_FUNCALL(rstrip,    "rstrip")
SV_DELEGATE_FUNCALL(chomp,     "chomp")
SV_DELEGATE_FUNCALL(chop,      "chop")
SV_DELEGATE_FUNCALL(reverse,   "reverse")
SV_DELEGATE_FUNCALL(squeeze,   "squeeze")
SV_DELEGATE_FUNCALL(encode,    "encode")
SV_DELEGATE_FUNCALL(gsub,      "gsub")
SV_DELEGATE_FUNCALL(sub,       "sub")
SV_DELEGATE_FUNCALL(tr,        "tr")
SV_DELEGATE_FUNCALL(tr_s,      "tr_s")
SV_DELEGATE_FUNCALL(sv_delete, "delete")
SV_DELEGATE_FUNCALL(count,     "count")
SV_DELEGATE_FUNCALL(scan,      "scan")
SV_DELEGATE_FUNCALL(split,     "split")
SV_DELEGATE_FUNCALL(center,    "center")
SV_DELEGATE_FUNCALL(ljust,     "ljust")
SV_DELEGATE_FUNCALL(rjust,     "rjust")
SV_DELEGATE_FUNCALL(format_op, "%")
SV_DELEGATE_FUNCALL(plus,      "+")
SV_DELEGATE_FUNCALL(multiply,  "*")
SV_DELEGATE_FUNCALL(unpack1,   "unpack1")
SV_DELEGATE_FUNCALL(scrub,     "scrub")
SV_DELEGATE_FUNCALL(unicode_normalize, "unicode_normalize")

/* ========================================================================= */
/* Bang methods — always raise FrozenError                                   */
/* ========================================================================= */

static VALUE sv_frozen_error(int argc, VALUE *argv, VALUE self) {
    VALUE str = sv_to_s(self);
    rb_raise(rb_eFrozenError, "can't modify frozen StringView: \"%s\"",
             StringValueCStr(str));
    return Qnil;
}

/* ========================================================================= */
/* Init                                                                      */
/* ========================================================================= */

void Init_string_view(void) {
    enc_utf8 = rb_utf8_encoding();

    cStringView = rb_define_class("StringView", rb_cObject);
    rb_include_module(cStringView, rb_mComparable);

    rb_define_alloc_func(cStringView, sv_alloc);
    rb_define_method(cStringView, "initialize", sv_initialize, -1);

    rb_define_method(cStringView, "to_s",       sv_to_s,       0);
    rb_define_method(cStringView, "inspect",    sv_inspect,    0);
    rb_define_method(cStringView, "frozen?",    sv_frozen_p,   0);
    rb_define_method(cStringView, "reset!",     sv_reset,      3);
    rb_define_alias(cStringView,  "materialize", "to_s");

    rb_define_method(cStringView, "bytesize",    sv_bytesize,    0);
    rb_define_method(cStringView, "length",      sv_length,      0);
    rb_define_alias(cStringView,  "size",        "length");
    rb_define_method(cStringView, "empty?",      sv_empty_p,     0);
    rb_define_method(cStringView, "encoding",    sv_encoding,    0);
    rb_define_method(cStringView, "ascii_only?", sv_ascii_only_p,0);

    rb_define_method(cStringView, "include?",    sv_include_p,   1);
    rb_define_method(cStringView, "start_with?", sv_start_with_p,-1);
    rb_define_method(cStringView, "end_with?",   sv_end_with_p, -1);
    rb_define_method(cStringView, "index",       sv_index,      -1);
    rb_define_method(cStringView, "rindex",      sv_rindex,     -1);
    rb_define_method(cStringView, "getbyte",     sv_getbyte,     1);
    rb_define_method(cStringView, "byteindex",   sv_byteindex,  -1);
    rb_define_method(cStringView, "byterindex",  sv_byterindex, -1);

    rb_define_method(cStringView, "each_byte",   sv_each_byte,   0);
    rb_define_method(cStringView, "each_char",   sv_each_char,   0);
    rb_define_method(cStringView, "bytes",       sv_bytes,       0);
    rb_define_method(cStringView, "chars",       sv_chars,       0);

    rb_define_method(cStringView, "match",       sv_match,      -1);
    rb_define_method(cStringView, "match?",      sv_match_p,    -1);
    rb_define_method(cStringView, "=~",          sv_match_operator, 1);

    rb_define_method(cStringView, "to_i",        sv_to_i,       -1);
    rb_define_method(cStringView, "to_f",        sv_to_f,        0);
    rb_define_method(cStringView, "hex",         sv_hex,         0);
    rb_define_method(cStringView, "oct",         sv_oct,         0);

    rb_define_method(cStringView, "==",          sv_eq,          1);
    rb_define_method(cStringView, "<=>",         sv_cmp,         1);
    rb_define_method(cStringView, "eql?",        sv_eql_p,       1);
    rb_define_method(cStringView, "hash",        sv_hash,        0);

    rb_define_method(cStringView, "[]",          sv_aref,       -1);
    rb_define_alias(cStringView,  "slice",       "[]");
    rb_define_method(cStringView, "byteslice",   sv_byteslice,  -1);

    rb_define_method(cStringView, "upcase",      sv_upcase,     -1);
    rb_define_method(cStringView, "downcase",    sv_downcase,   -1);
    rb_define_method(cStringView, "capitalize",  sv_capitalize, -1);
    rb_define_method(cStringView, "swapcase",    sv_swapcase,   -1);
    rb_define_method(cStringView, "strip",       sv_strip,      -1);
    rb_define_method(cStringView, "lstrip",      sv_lstrip,     -1);
    rb_define_method(cStringView, "rstrip",      sv_rstrip,     -1);
    rb_define_method(cStringView, "chomp",       sv_chomp,      -1);
    rb_define_method(cStringView, "chop",        sv_chop,       -1);
    rb_define_method(cStringView, "reverse",     sv_reverse,    -1);
    rb_define_method(cStringView, "squeeze",     sv_squeeze,    -1);
    rb_define_method(cStringView, "encode",      sv_encode,     -1);
    rb_define_method(cStringView, "gsub",        sv_gsub,       -1);
    rb_define_method(cStringView, "sub",         sv_sub,        -1);
    rb_define_method(cStringView, "tr",          sv_tr,         -1);
    rb_define_method(cStringView, "tr_s",        sv_tr_s,       -1);
    rb_define_method(cStringView, "delete",      sv_sv_delete,  -1);
    rb_define_method(cStringView, "count",       sv_count,      -1);
    rb_define_method(cStringView, "scan",        sv_scan,       -1);
    rb_define_method(cStringView, "split",       sv_split,      -1);
    rb_define_method(cStringView, "center",      sv_center,     -1);
    rb_define_method(cStringView, "ljust",       sv_ljust,      -1);
    rb_define_method(cStringView, "rjust",       sv_rjust,      -1);
    rb_define_method(cStringView, "%",           sv_format_op,  -1);
    rb_define_method(cStringView, "+",           sv_plus,       -1);
    rb_define_method(cStringView, "*",           sv_multiply,   -1);
    rb_define_method(cStringView, "unpack1",     sv_unpack1,    -1);
    rb_define_method(cStringView, "scrub",       sv_scrub,      -1);
    rb_define_method(cStringView, "unicode_normalize", sv_unicode_normalize, -1);

    rb_define_method(cStringView, "upcase!",     sv_frozen_error, -1);
    rb_define_method(cStringView, "downcase!",   sv_frozen_error, -1);
    rb_define_method(cStringView, "capitalize!", sv_frozen_error, -1);
    rb_define_method(cStringView, "swapcase!",   sv_frozen_error, -1);
    rb_define_method(cStringView, "strip!",      sv_frozen_error, -1);
    rb_define_method(cStringView, "lstrip!",     sv_frozen_error, -1);
    rb_define_method(cStringView, "rstrip!",     sv_frozen_error, -1);
    rb_define_method(cStringView, "chomp!",      sv_frozen_error, -1);
    rb_define_method(cStringView, "chop!",       sv_frozen_error, -1);
    rb_define_method(cStringView, "squeeze!",    sv_frozen_error, -1);
    rb_define_method(cStringView, "tr!",         sv_frozen_error, -1);
    rb_define_method(cStringView, "delete!",     sv_frozen_error, -1);
    rb_define_method(cStringView, "replace",     sv_frozen_error, -1);
    rb_define_method(cStringView, "reverse!",    sv_frozen_error, -1);
    rb_define_method(cStringView, "gsub!",       sv_frozen_error, -1);
    rb_define_method(cStringView, "sub!",        sv_frozen_error, -1);
    rb_define_method(cStringView, "slice!",      sv_frozen_error, -1);
}
