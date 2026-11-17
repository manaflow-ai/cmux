#ifndef CMUX_SIGN_CLONE_SWEEP_H
#define CMUX_SIGN_CLONE_SWEEP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Removes the Chromium code-sign clones earlier launches left in
// confstr(_CS_DARWIN_USER_TEMP_DIR)/../X/<bundle_id>.code_sign_clone
// (cmux-tui/crates/cmux-app-ffi/src/sign_clone_sweep.rs). Call once per
// launch, off the main thread, after the browser engine started. A clone is
// removed only when it is named code_sign_clone.XXXXXX, is a real folder,
// was created and last changed before this process started, and none of its
// executables is open elsewhere (Chromium's FSIOC_FD_ONLY_OPEN_ONCE test; no
// process is listed). Returns the number removed, or -1 for a null or
// non-UTF-8 bundle_id or when the temp folder or start time cannot be read.
int32_t cmux_sign_clone_sweep(const char *bundle_id);

#ifdef __cplusplus
}
#endif
#endif
