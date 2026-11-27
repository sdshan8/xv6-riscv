#ifndef ARCH_H
#define ARCH_H
#if defined(__riscv)
#include "riscv.h"
#elif defined(__aarch64__)
#include "aarch64.h"
#endif
#endif