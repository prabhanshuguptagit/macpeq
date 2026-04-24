#include "CAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>

struct atomic_int32_box {
    _Atomic int32_t value;
};

catomic_int32_t catomics_create_int32(int32_t initial) {
    struct atomic_int32_box* box = malloc(sizeof(struct atomic_int32_box));
    atomic_init(&box->value, initial);
    return box;
}

void catomics_destroy_int32(catomic_int32_t ptr) {
    free(ptr);
}

int32_t catomics_load_int32(catomic_int32_t ptr) {
    struct atomic_int32_box* box = ptr;
    return atomic_load_explicit(&box->value, memory_order_acquire);
}

void catomics_store_int32(catomic_int32_t ptr, int32_t value) {
    struct atomic_int32_box* box = ptr;
    atomic_store_explicit(&box->value, value, memory_order_release);
}

int32_t catomics_exchange_int32(catomic_int32_t ptr, int32_t desired) {
    struct atomic_int32_box* box = ptr;
    return atomic_exchange_explicit(&box->value, desired, memory_order_acq_rel);
}

int32_t catomics_add_int32(catomic_int32_t ptr, int32_t delta) {
    struct atomic_int32_box* box = ptr;
    return atomic_fetch_add_explicit(&box->value, delta, memory_order_relaxed);
}
