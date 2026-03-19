#ifndef STRING_VIEW_H
#define STRING_VIEW_H

#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/re.h"
#include "simdutf_c.h"

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

/*
 * Stride index: maps every STRIDE_CHARS-th character to its byte offset.
 * Built lazily on first char-indexed access. Enables O(1) char→byte
 * lookup for any offset (small scalar scan within one stride).
 */
#define STRIDE_CHARS 128

typedef struct {
    long *offsets;   /* offsets[i] = byte offset of character i*STRIDE_CHARS */
    long  count;     /* number of entries = ceil(charlen / STRIDE_CHARS) + 1 */
} stride_index_t;

typedef struct {
    VALUE  backing;     /* frozen String that owns the bytes */
    const char *base;   /* cached RSTRING_PTR(backing) — avoids indirection */
    rb_encoding *enc;   /* cached encoding — avoids rb_enc_get per call */
    long   offset;      /* byte offset into backing */
    long   length;      /* byte length of this view */
    long   charlen;     /* cached character count; -1 = not yet computed */
    int    single_byte; /* cached: 1 if char==byte (ASCII/single-byte enc), 0 if multibyte, -1 unknown */
    stride_index_t *stride_idx; /* lazily built stride index for multibyte, NULL if not built */
} string_view_t;

/* Global class/error VALUE variables */
extern VALUE cStringView;
extern VALUE cStringViewStrict;
extern VALUE cStringViewPool;
extern VALUE eWouldAllocate;

/* TypedData descriptor */
extern const rb_data_type_t string_view_type;

/* ========================================================================= */
/* Shared helpers                                                            */
/* ========================================================================= */

/* Forward-declared helpers (defined in string_view.c) */
int sv_compute_single_byte(VALUE backing, rb_encoding *enc);

/* Validate that str is a frozen T_STRING. Raises TypeError if not a
 * String, FrozenError if not frozen. */
SV_INLINE void sv_check_frozen_string(VALUE str) {
    if (SV_UNLIKELY(!RB_TYPE_P(str, T_STRING))) {
        rb_raise(rb_eTypeError,
                 "no implicit conversion of %s into String",
                 rb_obj_classname(str));
    }
    if (SV_UNLIKELY(!OBJ_FROZEN(str))) {
        rb_raise(rb_eFrozenError,
                 "string must be frozen; call .freeze before creating a view");
    }
}

/* Validate byte offset + length against a backing string's bytesize.
 * Uses overflow-safe comparison (checks off > max before subtracting). */
SV_INLINE void sv_check_bounds(long off, long len, long backing_len) {
    if (SV_UNLIKELY(off < 0 || len < 0 || off > backing_len ||
                     len > backing_len - off)) {
        rb_raise(rb_eArgError,
                 "offset %ld, length %ld out of range for string of bytesize %ld",
                 off, len, backing_len);
    }
}

/*
 * Initialize (or reinitialize) a string_view_t's fields from a frozen backing
 * string. Caller is responsible for freeing any prior stride_idx.
 */
SV_INLINE void sv_init_fields(VALUE obj, string_view_t *sv, VALUE backing,
                              const char *base, rb_encoding *enc,
                              long offset, long length) {
    RB_OBJ_WRITE(obj, &sv->backing, backing);
    sv->base        = base;
    sv->enc         = enc;
    sv->offset      = offset;
    sv->length      = length;
    sv->single_byte = sv_compute_single_byte(backing, enc);
    sv->charlen     = -1;
    sv->stride_idx  = NULL;
}

/* ========================================================================= */
/* Functions shared across compilation units                                 */
/* ========================================================================= */

/* Search functions (defined in string_view.c, used by Strict) */
VALUE sv_index(int argc, VALUE *argv, VALUE self);
VALUE sv_rindex(int argc, VALUE *argv, VALUE self);
VALUE sv_byteindex(int argc, VALUE *argv, VALUE self);
VALUE sv_byterindex(int argc, VALUE *argv, VALUE self);

/* Pool view (defined in string_view_pool.c, used by core_ext) */
VALUE pool_view(VALUE self, VALUE voffset, VALUE vlength);

/* Init functions for submodules */
void Init_string_view_strict(void);
void Init_string_view_pool(void);
void Init_string_view_core_ext(void);

#endif /* STRING_VIEW_H */
