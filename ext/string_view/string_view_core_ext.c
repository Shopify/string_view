#include "string_view.h"

/* ========================================================================= */
/* StringView::CoreExt — module with String#view, included on demand         */
/* ========================================================================= */

/*
 * view(byte_offset, byte_length) → StringView
 *
 * Returns a StringView into this string at the given byte range.
 * The backing string is frozen in place so StringView can safely reference it.
 * Each call returns a fresh StringView; callers that want explicit object reuse
 * should opt into StringView::Pool directly.
 */
static VALUE string_view_method(VALUE self, VALUE voffset, VALUE vlength) {
    VALUE args[3];

    rb_str_freeze(self);

    args[0] = self;
    args[1] = voffset;
    args[2] = vlength;
    return rb_class_new_instance(3, args, cStringView);
}

void Init_string_view_core_ext(void) {
    VALUE mCoreExt = rb_define_module_under(cStringView, "CoreExt");
    rb_define_method(mCoreExt, "view", string_view_method, 2);
}
