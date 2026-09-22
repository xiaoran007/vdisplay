#ifndef VDISPLAY_BRIDGE_H
#define VDISPLAY_BRIDGE_H
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// Caller owns the handle; release it exactly once with VDRelease.
bool VDCheckAPI(char *error, size_t capacity);
void *VDCreate(CFStringRef name, uint32_t width, uint32_t height, uint32_t scale,
               double refresh, uint32_t serial, char *error, size_t capacity);
uint32_t VDDisplayID(void *handle);
void VDRelease(void *handle);
#endif
