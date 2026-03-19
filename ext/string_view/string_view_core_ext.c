#include "string_view.h"

/* ========================================================================= */
/* StringView::CoreExt — module with String#view, included on demand         */
/* ========================================================================= */

/* ObjectSpace::WeakKeyMap caching String → Pool.
 * Keys (strings) are held weakly — when a string is GC'd, its entry
 * is automatically removed. Values (pools) are held strongly. */
static VALUE pool_cache;
static ID id_aref;
static ID id_aset;

/*
 * view(byte_offset, byte_length) → StringView
 *
 * Returns a StringView into this string at the given byte range.
 * Lazily creates a StringView::Pool and caches it in a global
 * WeakKeyMap for automatic cleanup when the string is GC'd.
 */
static VALUE string_view_method(VALUE self, VALUE voffset, VALUE vlength) {
    rb_str_freeze(self);

    VALUE pool = rb_funcall(pool_cache, id_aref, 1, self);
    if (NIL_P(pool)) {
        pool = rb_class_new_instance(1, &self, cStringViewPool);
        rb_funcall(pool_cache, id_aset, 2, self, pool);
    }
    return pool_view(pool, voffset, vlength);
}

void Init_string_view_core_ext(void) {
    id_aref = rb_intern("[]");
    id_aset = rb_intern("[]=");

    VALUE cWeakKeyMap = rb_const_get(
        rb_const_get(rb_cObject, rb_intern("ObjectSpace")),
        rb_intern("WeakKeyMap"));
    pool_cache = rb_class_new_instance(0, NULL, cWeakKeyMap);
    rb_gc_register_mark_object(pool_cache);

    VALUE mCoreExt = rb_define_module_under(cStringView, "CoreExt");
    rb_define_method(mCoreExt, "view", string_view_method, 2);
}
