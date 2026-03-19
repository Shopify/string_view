#include "string_view.h"

/* ========================================================================= */
/* StringView::Pool                                                          */
/* ========================================================================= */

VALUE cStringViewPool;

#define POOL_INITIAL_CAP 32
#define POOL_MAX_GROW    4096

typedef struct {
    VALUE   backing;      /* frozen String that owns the bytes */
    const char *base;     /* cached RSTRING_PTR(backing) */
    rb_encoding *enc;     /* cached encoding */
    int     single_byte;  /* cached single-byte flag */
    long    backing_len;  /* cached RSTRING_LEN(backing) */
    VALUE   views;        /* Ruby Array of pre-allocated StringView objects */
    long    next_idx;     /* index of next available view in the array */
    long    capacity;     /* current size of the views array */
} sv_pool_t;

static void pool_mark(void *ptr) {
    sv_pool_t *pool = (sv_pool_t *)ptr;
    if (pool->backing != Qnil)
        rb_gc_mark_movable(pool->backing);
    if (pool->views != Qnil)
        rb_gc_mark_movable(pool->views);
}

static void pool_compact(void *ptr) {
    sv_pool_t *pool = (sv_pool_t *)ptr;
    if (pool->backing != Qnil) {
        pool->backing = rb_gc_location(pool->backing);
        pool->base = RSTRING_PTR(pool->backing);
    }
    if (pool->views != Qnil) {
        pool->views = rb_gc_location(pool->views);
    }
}

static size_t pool_memsize(const void *ptr) {
    const sv_pool_t *pool = (const sv_pool_t *)ptr;
    size_t size = sizeof(sv_pool_t);
    /* Each pre-allocated view is a separate GC object with a string_view_t
     * struct. Report their cost here so ObjectSpace.memsize_of gives a
     * realistic picture of the pool's total footprint. */
    size += (size_t)pool->capacity * sizeof(string_view_t);
    return size;
}

static const rb_data_type_t pool_type = {
    .wrap_struct_name = "StringView::Pool",
    .function = { .dmark = pool_mark, .dfree = RUBY_DEFAULT_FREE,
                  .dsize = pool_memsize, .dcompact = pool_compact },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_EMBEDDABLE,
};

/*
 * Allocate a batch of StringView objects pre-initialized with the pool's
 * backing string. They start with offset=0, length=0 (empty views).
 * The `.view()` method sets the real offset+length before returning.
 */
static void pool_grow(sv_pool_t *pool, VALUE pool_obj) {
    long grow = pool->capacity == 0 ? POOL_INITIAL_CAP : pool->capacity;
    if (grow > POOL_MAX_GROW) grow = POOL_MAX_GROW;
    long new_cap = pool->capacity + grow;
    long old_cap = pool->capacity;

    /* Grow the Ruby Array to hold the new views */
    for (long i = old_cap; i < new_cap; i++) {
        string_view_t *sv;
        VALUE obj = TypedData_Make_Struct(cStringView, string_view_t,
                                         &string_view_type, sv);
        sv_init_fields(obj, sv, pool->backing, pool->base, pool->enc, 0, 0);
        rb_ary_push(pool->views, obj);
    }

    pool->capacity = new_cap;
}

/*
 * Pool.new(string) → Pool
 */
static VALUE pool_initialize(VALUE self, VALUE str) {
    sv_pool_t *pool = (sv_pool_t *)RTYPEDDATA_GET_DATA(self);
    sv_check_frozen_string(str);

    RB_OBJ_WRITE(self, &pool->backing, str);
    pool->base        = RSTRING_PTR(str);
    pool->enc         = rb_enc_get(str);
    pool->single_byte = sv_compute_single_byte(str, pool->enc);
    pool->backing_len = RSTRING_LEN(str);

    /* Create the views array and pre-allocate the initial batch */
    VALUE ary = rb_ary_new_capa(POOL_INITIAL_CAP);
    RB_OBJ_WRITE(self, &pool->views, ary);
    pool->next_idx = 0;
    pool->capacity = 0;

    pool_grow(pool, self);

    return self;
}

static VALUE pool_alloc(VALUE klass) {
    sv_pool_t *pool;
    VALUE obj = TypedData_Make_Struct(klass, sv_pool_t, &pool_type, pool);
    pool->backing     = Qnil;
    pool->base        = NULL;
    pool->enc         = NULL;
    pool->single_byte = -1;
    pool->backing_len = 0;
    pool->views       = Qnil;
    pool->next_idx    = 0;
    pool->capacity    = 0;
    return obj;
}

/*
 * pool.view(byte_offset, byte_length) → StringView
 *
 * Returns a pre-allocated StringView pointed at the given byte range.
 * If the pool is exhausted, grows exponentially before returning.
 */
VALUE pool_view(VALUE self, VALUE voffset, VALUE vlength) {
    sv_pool_t *pool = (sv_pool_t *)RTYPEDDATA_GET_DATA(self);

    /* Refresh cached base/len from the live backing string so that views
     * created after a mutation always see the current buffer pointer. */
    pool->base        = RSTRING_PTR(pool->backing);
    pool->backing_len = RSTRING_LEN(pool->backing);

    long off = NUM2LONG(voffset);
    long len = NUM2LONG(vlength);

    sv_check_bounds(off, len, pool->backing_len);

    /* Grow if exhausted */
    if (SV_UNLIKELY(pool->next_idx >= pool->capacity)) {
        pool_grow(pool, self);
    }

    /* Grab the next pre-allocated view and set its range */
    VALUE view = RARRAY_AREF(pool->views, pool->next_idx);
    pool->next_idx++;

    string_view_t *sv = (string_view_t *)RTYPEDDATA_GET_DATA(view);
    sv->base    = pool->base;   /* refresh in case backing was mutated */
    sv->offset  = off;
    sv->length  = len;
    sv->charlen = -1;           /* invalidate cached char count */
    sv->stride_idx = NULL;      /* invalidate stride index */

    return view;
}

/*
 * pool.size → Integer
 * Number of views handed out so far.
 */
static VALUE pool_size(VALUE self) {
    sv_pool_t *pool = (sv_pool_t *)RTYPEDDATA_GET_DATA(self);
    return LONG2NUM(pool->next_idx);
}

/*
 * pool.capacity → Integer
 * Current number of pre-allocated view slots.
 */
static VALUE pool_capacity(VALUE self) {
    sv_pool_t *pool = (sv_pool_t *)RTYPEDDATA_GET_DATA(self);
    return LONG2NUM(pool->capacity);
}

/*
 * pool.reset! → self
 * Reset the cursor to 0, allowing all pre-allocated views to be reused.
 * Previously returned views become invalid (their offsets may be overwritten).
 */
static VALUE pool_reset(VALUE self) {
    sv_pool_t *pool = (sv_pool_t *)RTYPEDDATA_GET_DATA(self);
    pool->next_idx = 0;
    return self;
}

/*
 * pool.backing → String (frozen)
 */
static VALUE pool_backing(VALUE self) {
    sv_pool_t *pool = (sv_pool_t *)RTYPEDDATA_GET_DATA(self);
    return pool->backing;
}

void Init_string_view_pool(void) {
    cStringViewPool = rb_define_class_under(cStringView, "Pool", rb_cObject);
    rb_define_alloc_func(cStringViewPool, pool_alloc);
    rb_define_method(cStringViewPool, "initialize", pool_initialize, 1);
    rb_define_method(cStringViewPool, "view",       pool_view,       2);
    rb_define_method(cStringViewPool, "size",       pool_size,       0);
    rb_define_method(cStringViewPool, "capacity",   pool_capacity,   0);
    rb_define_method(cStringViewPool, "reset!",     pool_reset,      0);
    rb_define_method(cStringViewPool, "backing",    pool_backing,    0);
}
