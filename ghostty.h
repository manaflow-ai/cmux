#ifndef CMUX_GHOSTTY_BRIDGE_HEADER_H
#define CMUX_GHOSTTY_BRIDGE_HEADER_H

// Keep the Swift bridge on Ghostty's canonical C API header so Xcode and the
// bundled GhosttyKit stay ABI-aligned across submodule upgrades.
#include "ghostty/include/ghostty.h"

#endif
