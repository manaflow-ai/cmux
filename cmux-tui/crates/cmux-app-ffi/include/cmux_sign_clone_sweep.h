#ifndef CMUX_SIGN_CLONE_SWEEP_H
#define CMUX_SIGN_CLONE_SWEEP_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// One pass's result.
typedef struct CmuxSignCloneSweepReport {
  // st_blocks * 512 of the removed entries that had no other name.
  uint64_t reclaimed_bytes;
  // The volume's free space after the pass minus before it.
  int64_t free_space_delta_bytes;
  uint32_t removed;
  // Kept because something runs from them.
  uint32_t kept_in_use;
  // Kept because their bundle's Info.plist is not their root's family id.
  uint32_t kept_foreign;
  // The pass stopped at its budget with clones left to check.
  bool more;
} CmuxSignCloneSweepReport;

// One pass over the Chromium code-sign clones that cmux apps (com.cmuxterm.app
// and com.cmuxterm.app.*) left in confstr(_CS_DARWIN_USER_TEMP_DIR)/../X
// (cmux-tui/crates/cmux-app-ffi/src/sign_clone_sweep.rs). Run it at idle, off
// the main thread, in the launch's last stage; while out->more, run another
// pass later. A clone is removed only when its bundle's Info.plist names its
// root's family id, it was made before this process started, and none of its
// executables is open anywhere (Chromium's FSIOC_FD_ONLY_OPEN_ONCE test; no
// process is listed). Removes at most max_clones clones and stops once
// max_bytes are reclaimed. Returns false, with *out zeroed, when the temp
// folder or this process's start time cannot be read. out may be null.
bool cmux_sign_clone_sweep(uint64_t max_bytes, uint32_t max_clones, CmuxSignCloneSweepReport *out);

#ifdef __cplusplus
}
#endif
#endif
