// Copyright 2026 manaflow-ai. All rights reserved.
//
// cmux_layer_host.mm -- stub for the CAContext / CALayerHost wiring
// that backs cmux_view_t with cross-process compositing. The real
// implementation lives behind cmux_view_create and is not exposed
// through the C ABI; this file only exists so the framework's
// BUILD.gn has a place to put platform-specific compositor glue in
// future iterations (P2 in plans/chromium-engine.md). In the stub
// build it is intentionally empty.
//
// Lands at src/cmux/embedder/cmux_layer_host.mm in the fork.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

// Intentionally empty in the stub build.
