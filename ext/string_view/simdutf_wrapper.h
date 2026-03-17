/*
 * C declarations for simdutf functions we use.
 * simdutf exports these as C-linkage symbols from simdutf.cpp.
 */
#ifndef SIMDUTF_WRAPPER_H
#define SIMDUTF_WRAPPER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Count UTF-8 characters (code points) using SIMD. Assumes valid UTF-8. */
size_t simdutf_count_utf8(const char *input, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* SIMDUTF_WRAPPER_H */
