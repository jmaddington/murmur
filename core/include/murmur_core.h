#ifndef MURMUR_CORE_H
#define MURMUR_CORE_H
#include <stdint.h>
#include <stddef.h>

/// Dispatch a JSON command: {"cmd": "...", ...}. Returns a heap JSON string
/// {"ok": <result>} or {"error": "<message>"}; free it with murmur_free.
/// Blocking (may perform network I/O) — call off the main thread.
char *murmur_call(const char *json);
void murmur_free(char *ptr);

/// Encode mono float samples as 16-bit PCM WAV at `path`. Returns 0 on success.
int32_t murmur_write_wav(const float *samples, size_t len, uint32_t sample_rate, const char *path);

#endif
