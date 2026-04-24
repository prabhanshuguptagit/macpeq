#ifndef CATOMICS_H
#define CATOMICS_H

#include <stdint.h>

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

#ifdef __cplusplus
}
#endif

#endif
