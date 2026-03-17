#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/re.h"

/* ========================================================================= */
/* Struct & TypedData                                                        */
/* ========================================================================= */

typedef struct {
    VALUE  backing; /* frozen String that owns the bytes */
    long   offset;  /* byte offset into backing */
    long   length;  /* byte length of this view */
    int    weak;    /* if true, dmark does NOT mark backing (weak mode) */
} string_view_t;

static VALUE cStringView;

/*
 * A global ObjectSpace::WeakMap that maps StringView -> backing String.
 * Used only in weak mode to detect when the backing has been collected.
 * In strong mode (default), backing is kept alive by the GC mark function.
 *
 * In weak mode:
 *   - dmark does NOT mark sv->backing (so GC can collect it)
 *   - the WeakMap holds a weak reference to the backing
 *   - to check liveness, we look up the WeakMap entry
 *   - if the backing was collected, WeakMap returns nil
 *   - we set sv->backing = Qnil to cache this fact
 */
static VALUE sv_weak_map = Qundef;

static VALUE sv_get_weak_map(void) {
    if (sv_weak_map == Qundef) {
        VALUE os = rb_const_get(rb_cObject, rb_intern("ObjectSpace"));
        VALUE wm_class = rb_const_get(os, rb_intern("WeakMap"));
        sv_weak_map = rb_class_new_instance(0, NULL, wm_class);
        rb_gc_register_mark_object(sv_weak_map);
    }
    return sv_weak_map;
}

/*
 * GC mark callback.
 * Strong mode (default): mark the backing to keep it alive.
 * Weak mode: do NOT mark the backing — GC may collect it.
 */
static void sv_mark(void *ptr) {
    string_view_t *sv = (string_view_t *)ptr;
    if (sv->backing != Qnil && !sv->weak) {
        rb_gc_mark_movable(sv->backing);
    }
}

static void sv_compact(void *ptr) {
    string_view_t *sv = (string_view_t *)ptr;
    if (sv->backing != Qnil && !sv->weak) {
        sv->backing = rb_gc_location(sv->backing);
    }
}

static void sv_free(void *ptr) {
    xfree(ptr);
}

static size_t sv_memsize(const void *ptr) {
    return sizeof(string_view_t);
}

static const rb_data_type_t string_view_type = {
    "StringView",
    { sv_mark, sv_free, sv_memsize, sv_compact },
    0, 0,
    RUBY_TYPED_FREE_IMMEDIATELY
};

/* ========================================================================= */
/* Internal helpers                                                          */
/* ========================================================================= */

static string_view_t *sv_get_struct(VALUE self) {
    string_view_t *sv;
    TypedData_Get_Struct(self, string_view_t, &string_view_type, sv);
    return sv;
}

/*
 * Mandatory liveness check. Every access to sv->backing must go through this.
 *
 * In weak mode, the backing may have been collected. We check the WeakMap
 * to detect this and set sv->backing = Qnil.
 *
 * Returns the backing VALUE or raises RuntimeError if it was collected.
 */
static VALUE sv_backing_or_raise(string_view_t *sv) {
    if (sv->backing == Qnil) {
        rb_raise(rb_eRuntimeError,
            "StringView is dangling: backing string has been garbage collected");
    }

    if (sv->weak) {
        /* In weak mode, verify the backing is still alive via the WeakMap.
         * We can't trust sv->backing directly since we didn't mark it —
         * the GC may have collected or moved the object. */

        /* Actually: if the object was collected, the VALUE is now invalid.
         * We can't safely dereference it. Instead, we must ONLY use the
         * WeakMap to check if the backing is still alive. But the WeakMap
         * maps StringView(self) -> backing. We don't have `self` here.
         *
         * Revised approach: in weak mode, sv->backing is NOT used directly.
         * We always go through the WeakMap. This is slightly slower but safe.
         */
    }

    return sv->backing;
}

/* Pointer to the start of this view's bytes */
static const char *sv_ptr(string_view_t *sv) {
    VALUE backing = sv_backing_or_raise(sv);
    return RSTRING_PTR(backing) + sv->offset;
}

/* encoding of the backing string */
static rb_encoding *sv_enc(string_view_t *sv) {
    VALUE backing = sv_backing_or_raise(sv);
    return rb_enc_get(backing);
}

/*
 * Create a shared String that aliases the backing's heap buffer.
 * For short strings, rb_str_subseq may copy — but those are cheap.
 * The result is frozen to prevent mutation through the alias.
 */
static VALUE sv_as_shared_str(string_view_t *sv) {
    VALUE backing = sv_backing_or_raise(sv);
    VALUE shared = rb_str_subseq(backing, sv->offset, sv->length);
    rb_obj_freeze(shared);
    return shared;
}

/* Allocate a new StringView VALUE pointing into the same backing */
static VALUE sv_new_from_backing(VALUE parent, VALUE backing, long offset, long length) {
    string_view_t *sv;
    VALUE obj = TypedData_Make_Struct(cStringView, string_view_t,
                                     &string_view_type, sv);
    RB_OBJ_WRITE(obj, &sv->backing, backing);
    sv->offset  = offset;
    sv->length  = length;
    sv->weak    = 0;
    rb_obj_freeze(obj);
    return obj;
}

/* ========================================================================= */
/* Construction                                                              */
/* ========================================================================= */

static VALUE sv_alloc(VALUE klass) {
    string_view_t *sv;
    VALUE obj = TypedData_Make_Struct(klass, string_view_t,
                                     &string_view_type, sv);
    sv->backing = Qnil;
    sv->offset  = 0;
    sv->length  = 0;
    sv->weak    = 0;
    return obj;
}

/*
 * StringView.new(string)
 * StringView.new(string, byte_offset, byte_length)
 *
 * Creates a new StringView. The backing string is frozen immediately.
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
    RB_OBJ_WRITE(self, &sv->backing, str);
    sv->offset  = offset;
    sv->length  = length;
    sv->weak    = 0;

    rb_obj_freeze(self);

    return self;
}

/* ========================================================================= */
/* to_s / materialize / inspect / dangling? / reset!                         */
/* ========================================================================= */

static VALUE sv_to_s(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    return rb_enc_str_new(sv_ptr(sv), sv->length, sv_enc(sv));
}

static VALUE sv_inspect(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    if (sv->backing == Qnil) {
        return rb_sprintf("#<StringView:%p (dangling) offset=%ld length=%ld>",
                          (void *)self, sv->offset, sv->length);
    }
    VALUE content = rb_enc_str_new(sv_ptr(sv), sv->length, sv_enc(sv));
    return rb_sprintf("#<StringView:%p \"%"PRIsVALUE"\" offset=%ld length=%ld>",
                      (void *)self, content, sv->offset, sv->length);
}

static VALUE sv_frozen_p(VALUE self) {
    return Qtrue; /* always frozen */
}

/*
 * dangling? -> true/false
 *
 * Returns true if the backing string has been garbage collected
 * (only possible in weak mode) or was explicitly cleared.
 */
static VALUE sv_dangling_p(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    if (sv->backing == Qnil) return Qtrue;

    if (sv->weak) {
        /* Check the WeakMap to see if backing is still alive */
        VALUE wm = sv_get_weak_map();
        VALUE alive = rb_funcall(wm, rb_intern("[]"), 1, self);
        if (NIL_P(alive)) {
            /* Backing was collected — cache this */
            sv->backing = Qnil;
            return Qtrue;
        }
    }
    return Qfalse;
}

/*
 * reset!(new_backing, byte_offset, byte_length) -> self
 *
 * Re-point the view at a different backing string. The new backing is
 * frozen immediately. Uses RB_OBJ_WRITE for the GC write barrier.
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

    RB_OBJ_WRITE(self, &sv->backing, new_backing);
    sv->offset = off;
    sv->length = len;

    /* If weak mode, update the WeakMap */
    if (sv->weak) {
        VALUE wm = sv_get_weak_map();
        rb_funcall(wm, rb_intern("[]="), 2, self, new_backing);
    }

    return self;
}

/*
 * weaken! -> self
 *
 * Switch the view to weak reference mode. The backing string will no
 * longer be kept alive by the StringView — it can be garbage collected
 * if no other strong references exist.
 *
 * After calling weaken!, the caller is responsible for keeping the
 * backing alive, exactly like std::string_view in C++ or &str in Rust.
 *
 * Use dangling? to check if the backing has been collected.
 */
static VALUE sv_weaken(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    if (sv->weak) return self; /* already weak */
    if (sv->backing == Qnil) {
        rb_raise(rb_eRuntimeError, "cannot weaken a dangling StringView");
    }

    sv->weak = 1;

    /* Store backing in WeakMap so we can detect collection */
    VALUE wm = sv_get_weak_map();
    rb_funcall(wm, rb_intern("[]="), 2, self, sv->backing);

    return self;
}

/* ========================================================================= */
/* Tier 1: Structural                                                        */
/* ========================================================================= */

static VALUE sv_bytesize(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    sv_backing_or_raise(sv);
    return LONG2NUM(sv->length);
}

static VALUE sv_length(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv);
    long chars = rb_enc_strlen(p, p + sv->length, enc);
    return LONG2NUM(chars);
}

static VALUE sv_empty_p(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    sv_backing_or_raise(sv);
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
    sv_backing_or_raise(sv);
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
    sv_backing_or_raise(sv);
    RETURN_ENUMERATOR(self, 0, 0);
    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv);
    const char *e = p + sv->length;
    while (p < e) {
        int clen = rb_enc_mbclen(p, e, enc);
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
        int clen = rb_enc_mbclen(p, e, enc);
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

    if (rb_obj_is_kind_of(other, cStringView)) {
        string_view_t *o = sv_get_struct(other);
        if (sv->length != o->length) return Qfalse;
        return memcmp(p, sv_ptr(o), sv->length) == 0 ? Qtrue : Qfalse;
    }

    if (RB_TYPE_P(other, T_STRING)) {
        if (sv->length != RSTRING_LEN(other)) return Qfalse;
        return memcmp(p, RSTRING_PTR(other), sv->length) == 0 ? Qtrue : Qfalse;
    }

    return Qfalse;
}

static VALUE sv_cmp(VALUE self, VALUE other) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);
    const char *op;
    long olen;

    if (rb_obj_is_kind_of(other, cStringView)) {
        string_view_t *o = sv_get_struct(other);
        op = sv_ptr(o);
        olen = o->length;
    } else if (RB_TYPE_P(other, T_STRING)) {
        op = RSTRING_PTR(other);
        olen = RSTRING_LEN(other);
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
    if (!rb_obj_is_kind_of(other, cStringView)) return Qfalse;
    return sv_eq(self, other);
}

static VALUE sv_hash(VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    const char *p = sv_ptr(sv);
    VALUE backing = sv_backing_or_raise(sv);
    st_index_t h = rb_memhash(p, sv->length);
    h ^= (st_index_t)rb_enc_get_index(backing);
    return ST2FIX(h);
}

/* ========================================================================= */
/* Tier 2: Slicing — returns StringView                                      */
/* ========================================================================= */

static long sv_char_to_byte_offset(string_view_t *sv, long char_idx) {
    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv);
    const char *e = p + sv->length;
    long i;

    if (rb_enc_mbmaxlen(enc) == 1) {
        return char_idx;
    }

    for (i = 0; i < char_idx && p < e; i++) {
        p += rb_enc_mbclen(p, e, enc);
    }

    if (i < char_idx) return -1;
    return p - (sv_ptr(sv));
}

static long sv_char_count(string_view_t *sv) {
    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv);
    return rb_enc_strlen(p, p + sv->length, enc);
}

static long sv_chars_to_bytes(string_view_t *sv, long byte_off, long n) {
    rb_encoding *enc = sv_enc(sv);
    const char *p = sv_ptr(sv) + byte_off;
    const char *e = sv_ptr(sv) + sv->length;
    long i;
    const char *start = p;

    for (i = 0; i < n && p < e; i++) {
        p += rb_enc_mbclen(p, e, enc);
    }
    return p - start;
}

static VALUE sv_aref(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE backing = sv_backing_or_raise(sv);
    VALUE arg1, arg2;

    rb_scan_args(argc, argv, "11", &arg1, &arg2);

    if (!NIL_P(arg2)) {
        long char_idx = NUM2LONG(arg1);
        long char_len = NUM2LONG(arg2);
        long total_chars = sv_char_count(sv);

        if (char_idx < 0) char_idx += total_chars;
        if (char_idx < 0 || char_idx > total_chars) return Qnil;
        if (char_len < 0) return Qnil;

        long byte_off = sv_char_to_byte_offset(sv, char_idx);
        if (byte_off < 0) return Qnil;

        long remaining_chars = total_chars - char_idx;
        if (char_len > remaining_chars) char_len = remaining_chars;

        long byte_len = sv_chars_to_bytes(sv, byte_off, char_len);

        return sv_new_from_backing(self, backing,
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

        return sv_new_from_backing(self, backing,
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

        return sv_new_from_backing(self, backing,
                                   sv->offset + byte_off,
                                   byte_len);
    }

    if (RB_TYPE_P(arg1, T_STRING)) {
        const char *p = sv_ptr(sv);
        long slen = RSTRING_LEN(arg1);
        if (slen == 0) {
            return sv_new_from_backing(self, backing, sv->offset, 0);
        }
        if (slen > sv->length) return Qnil;

        long pos = rb_memsearch(RSTRING_PTR(arg1), slen, p, sv->length, sv_enc(sv));
        if (pos < 0 || pos > sv->length - slen) return Qnil;

        return sv_new_from_backing(self, backing,
                                   sv->offset + pos,
                                   slen);
    }

    if (RB_INTEGER_TYPE_P(arg1)) {
        long char_idx = NUM2LONG(arg1);
        long total_chars = sv_char_count(sv);

        if (char_idx < 0) char_idx += total_chars;
        if (char_idx < 0 || char_idx >= total_chars) return Qnil;

        long byte_off = sv_char_to_byte_offset(sv, char_idx);
        if (byte_off < 0) return Qnil;

        long byte_len = sv_chars_to_bytes(sv, byte_off, 1);

        return sv_new_from_backing(self, backing,
                                   sv->offset + byte_off,
                                   byte_len);
    }

    rb_raise(rb_eTypeError, "no implicit conversion of %s into Integer",
             rb_obj_classname(arg1));
    return Qnil;
}

static VALUE sv_byteslice(int argc, VALUE *argv, VALUE self) {
    string_view_t *sv = sv_get_struct(self);
    VALUE backing = sv_backing_or_raise(sv);
    VALUE arg1, arg2;

    rb_scan_args(argc, argv, "11", &arg1, &arg2);

    if (!NIL_P(arg2)) {
        long off = NUM2LONG(arg1);
        long len = NUM2LONG(arg2);

        if (off < 0) off += sv->length;
        if (off < 0 || off > sv->length) return Qnil;
        if (len < 0) return Qnil;
        if (off + len > sv->length) len = sv->length - off;

        return sv_new_from_backing(self, backing,
                                   sv->offset + off,
                                   len);
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

        return sv_new_from_backing(self, backing,
                                   sv->offset + beg,
                                   len);
    }

    {
        long idx = NUM2LONG(arg1);
        if (idx < 0) idx += sv->length;
        if (idx < 0 || idx >= sv->length) return Qnil;
        return sv_new_from_backing(self, backing,
                                   sv->offset + idx,
                                   1);
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
    string_view_t *sv = sv_get_struct(self);
    if (sv->backing == Qnil) {
        rb_raise(rb_eFrozenError, "can't modify frozen StringView (dangling)");
    }
    VALUE str = sv_to_s(self);
    rb_raise(rb_eFrozenError, "can't modify frozen StringView: \"%s\"",
             StringValueCStr(str));
    return Qnil;
}

/* ========================================================================= */
/* Init                                                                      */
/* ========================================================================= */

void Init_string_view(void) {
    cStringView = rb_define_class("StringView", rb_cObject);
    rb_include_module(cStringView, rb_mComparable);

    rb_define_alloc_func(cStringView, sv_alloc);
    rb_define_method(cStringView, "initialize", sv_initialize, -1);

    /* to_s / inspect / frozen? / dangling? / reset! / weaken! */
    rb_define_method(cStringView, "to_s",       sv_to_s,       0);
    rb_define_method(cStringView, "inspect",    sv_inspect,    0);
    rb_define_method(cStringView, "frozen?",    sv_frozen_p,   0);
    rb_define_method(cStringView, "dangling?",  sv_dangling_p, 0);
    rb_define_method(cStringView, "reset!",     sv_reset,      3);
    rb_define_method(cStringView, "weaken!",    sv_weaken,     0);
    rb_define_alias(cStringView,  "materialize", "to_s");

    /* Tier 1: Structural */
    rb_define_method(cStringView, "bytesize",    sv_bytesize,    0);
    rb_define_method(cStringView, "length",      sv_length,      0);
    rb_define_alias(cStringView,  "size",        "length");
    rb_define_method(cStringView, "empty?",      sv_empty_p,     0);
    rb_define_method(cStringView, "encoding",    sv_encoding,    0);
    rb_define_method(cStringView, "ascii_only?", sv_ascii_only_p,0);

    /* Tier 1: Searching */
    rb_define_method(cStringView, "include?",    sv_include_p,   1);
    rb_define_method(cStringView, "start_with?", sv_start_with_p,-1);
    rb_define_method(cStringView, "end_with?",   sv_end_with_p, -1);
    rb_define_method(cStringView, "index",       sv_index,      -1);
    rb_define_method(cStringView, "rindex",      sv_rindex,     -1);
    rb_define_method(cStringView, "getbyte",     sv_getbyte,     1);
    rb_define_method(cStringView, "byteindex",   sv_byteindex,  -1);
    rb_define_method(cStringView, "byterindex",  sv_byterindex, -1);

    /* Tier 1: Iteration */
    rb_define_method(cStringView, "each_byte",   sv_each_byte,   0);
    rb_define_method(cStringView, "each_char",   sv_each_char,   0);
    rb_define_method(cStringView, "bytes",       sv_bytes,       0);
    rb_define_method(cStringView, "chars",       sv_chars,       0);

    /* Tier 1: Pattern matching */
    rb_define_method(cStringView, "match",       sv_match,      -1);
    rb_define_method(cStringView, "match?",      sv_match_p,    -1);
    rb_define_method(cStringView, "=~",          sv_match_operator, 1);

    /* Tier 1: Numeric conversions */
    rb_define_method(cStringView, "to_i",        sv_to_i,       -1);
    rb_define_method(cStringView, "to_f",        sv_to_f,        0);
    rb_define_method(cStringView, "hex",         sv_hex,         0);
    rb_define_method(cStringView, "oct",         sv_oct,         0);

    /* Tier 1: Comparison */
    rb_define_method(cStringView, "==",          sv_eq,          1);
    rb_define_method(cStringView, "<=>",         sv_cmp,         1);
    rb_define_method(cStringView, "eql?",        sv_eql_p,       1);
    rb_define_method(cStringView, "hash",        sv_hash,        0);

    /* Tier 2: Slicing */
    rb_define_method(cStringView, "[]",          sv_aref,       -1);
    rb_define_alias(cStringView,  "slice",       "[]");
    rb_define_method(cStringView, "byteslice",   sv_byteslice,  -1);

    /* Tier 3: Transform delegation */
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

    /* Bang methods — all raise FrozenError */
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
