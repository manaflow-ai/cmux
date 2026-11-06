// C ABI of cmux-wg-tun: the WireGuard engine of the opt-in cmux Cloud Tunnel
// system extension. It moves packets between the provider's utun fd and one
// UDP socket to the WireGuard endpoint, with boringtun doing the crypto.
#ifndef CMUX_WG_TUN_H
#define CMUX_WG_TUN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxWgTun CmuxWgTun;

typedef struct CmuxWgTunStats {
  uint64_t tx_bytes;
  uint64_t rx_bytes;
  // Unix seconds of the last completed handshake, 0 when none yet.
  int64_t last_handshake_unix;
} CmuxWgTunStats;

// The utun control socket NetworkExtension opened for this provider, or -1.
int32_t cmux_wg_tun_find_utun_fd(void);

// Starts the engine on `tun_fd` with a completed wg-quick config (UTF-8, NUL
// terminated, PrivateKey filled in). Returns NULL and writes a NUL-terminated
// reason into `error` (when `error_len` > 0) on failure. The fd stays owned
// by the caller.
CmuxWgTun *cmux_wg_tun_start(const char *config, int32_t tun_fd, char *error, size_t error_len);

// The default route changed: rebind the UDP socket and re-handshake a stale
// session.
void cmux_wg_tun_network_changed(CmuxWgTun *tun);

void cmux_wg_tun_stats(const CmuxWgTun *tun, CmuxWgTunStats *out);

// Stops the engine, joins its thread and frees `tun`.
void cmux_wg_tun_stop(CmuxWgTun *tun);

#ifdef __cplusplus
}
#endif

#endif
