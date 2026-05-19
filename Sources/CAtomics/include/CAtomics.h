#ifndef CATOMICS_H
#define CATOMICS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* catomic_int32_t;

catomic_int32_t catomics_create_int32(int32_t initial);
void catomics_destroy_int32(catomic_int32_t ptr);
int32_t catomics_load_int32(catomic_int32_t ptr);
void catomics_store_int32(catomic_int32_t ptr, int32_t value);
int32_t catomics_exchange_int32(catomic_int32_t ptr, int32_t desired);
int32_t catomics_add_int32(catomic_int32_t ptr, int32_t delta);

/// Enable flush-to-zero mode (FPCR.FZ on ARM64, MXCSR.FTZ+DAZ on x86).
/// Idempotent: safe to call repeatedly from any thread. Cost is negligible
/// (~5-10ns) compared to the denormal stalls it prevents (100x slowdown).
void catomics_enable_denormal_suppression(void);

#ifdef __cplusplus
}
#endif

#endif
