#include "CAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

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

// MARK: - Denormal/Subnormal Floating-Point Suppression

void catomics_enable_denormal_suppression(void) {
#if defined(__aarch64__)
    // ARM64: Set FPCR.FZ (bit 24) - flush subnormal outputs to zero.
    // Note: on AArch64, FZ also flushes subnormal inputs (unlike x86).
    uint64_t fpcr;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
    __asm__ __volatile__("msr fpcr, %0" : : "r"(fpcr | (1ULL << 24)));
#elif defined(__x86_64__) || defined(__i386__)
    // x86_64: Set MXCSR.FTZ (bit 15) and MXCSR.DAZ (bit 6).
    // DAZ: treat subnormal inputs as zero. FTZ: flush subnormal outputs.
    uint32_t mxcsr;
    __asm__ __volatile__("stmxcsr %0" : "=m"(mxcsr));
    mxcsr |= (1U << 15) | (1U << 6);
    __asm__ __volatile__("ldmxcsr %0" : : "m"(mxcsr));
#endif
}
