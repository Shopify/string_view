#include "string_view.h"

/* ========================================================================= */
/* StringView::Strict — raises WouldAllocate for any allocating method       */
/* ========================================================================= */

/*
 * Raise StringView::WouldAllocate with the method name.
 * Used for all methods on Strict that would create a String.
 */
static VALUE sv_would_allocate(int argc, VALUE *argv, VALUE self) {
    const char *method_name = rb_id2name(rb_frame_this_func());
    rb_raise(eWouldAllocate,
             "StringView::Strict#%s would allocate a String — "
             "call .materialize to get a String, or .reset! to repoint the view",
             method_name);
    return Qnil;
}

/*
 * Strict versions of index/rindex/byteindex/byterindex:
 * String args work zero-alloc. Regexp args raise WouldAllocate.
 */
#define SV_STRICT_SEARCH(cname, method_str, base_fn)                        \
    static VALUE sv_strict_##cname(int argc, VALUE *argv, VALUE self) {     \
        if (argc >= 1 && rb_obj_is_kind_of(argv[0], rb_cRegexp)) {         \
            rb_raise(eWouldAllocate,                                        \
                     "StringView::Strict#" method_str " with Regexp would " \
                     "allocate a String — call .materialize to get a "      \
                     "String, or .reset! to repoint the view");             \
        }                                                                   \
        return base_fn(argc, argv, self);                                   \
    }

SV_STRICT_SEARCH(index,      "index",      sv_index)
SV_STRICT_SEARCH(rindex,     "rindex",     sv_rindex)
SV_STRICT_SEARCH(byteindex,  "byteindex",  sv_byteindex)
SV_STRICT_SEARCH(byterindex, "byterindex", sv_byterindex)

void Init_string_view_strict(void) {
    eWouldAllocate = rb_define_class_under(cStringView, "WouldAllocate", rb_eRuntimeError);

    cStringViewStrict = rb_define_class_under(cStringView, "Strict", cStringView);

    /* Strict inherits everything from StringView (including alloc, initialize,
     * all zero-copy methods, slicing, comparisons, etc.).
     *
     * Override only methods that would allocate a String object.
     * to_s / materialize is the explicit escape hatch. */

    /* Tier 3 transforms — all allocate a result String */
    rb_define_method(cStringViewStrict, "upcase",      sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "downcase",    sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "capitalize",  sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "swapcase",    sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "reverse",     sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "squeeze",     sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "encode",      sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "gsub",        sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "sub",         sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "tr",          sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "tr_s",        sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "delete",      sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "scan",        sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "split",       sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "center",      sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "ljust",       sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "rjust",       sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "%",           sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "+",           sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "*",           sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "unpack1",     sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "scrub",       sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "unicode_normalize", sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "count",       sv_would_allocate, -1);

    /* index/rindex/byteindex/byterindex: String args are zero-alloc,
     * Regexp args raise WouldAllocate. */
    rb_define_method(cStringViewStrict, "index",       sv_strict_index,       -1);
    rb_define_method(cStringViewStrict, "rindex",      sv_strict_rindex,      -1);
    rb_define_method(cStringViewStrict, "byteindex",   sv_strict_byteindex,   -1);
    rb_define_method(cStringViewStrict, "byterindex",  sv_strict_byterindex,  -1);

    /* Regex-based methods — always allocate */
    rb_define_method(cStringViewStrict, "match",       sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "match?",      sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "=~",          sv_would_allocate, -1);

    /* Iteration methods that yield/return Strings */
    rb_define_method(cStringViewStrict, "each_char",   sv_would_allocate, -1);
    rb_define_method(cStringViewStrict, "chars",       sv_would_allocate, -1);

    /* Implicit coercion — would create a shared String */
    rb_define_private_method(cStringViewStrict, "to_str", sv_would_allocate, -1);

    /* inspect allocates a String (but we keep it — debugging is essential) */

    /* to_s raises — Strict views act like frozen strings, not string sources.
     * materialize is the EXPLICIT escape hatch (inherited from StringView,
     * defined as a separate method pointing at sv_to_s). */
    rb_define_method(cStringViewStrict, "to_s",  sv_would_allocate, -1);
}
