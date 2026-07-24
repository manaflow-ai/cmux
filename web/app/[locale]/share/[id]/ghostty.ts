"use client";

// Lazy, browser-only loader for ghostty-web. The package embeds its
// ghostty-vt.wasm as a base64 data: URL inside the JS bundle and
// `init()` fetches that first, so no public/ copy or explicit wasm path
// is needed under Next's bundler.

type GhosttyModule = typeof import("ghostty-web");

let modulePromise: Promise<GhosttyModule> | null = null;

export function loadGhostty(): Promise<GhosttyModule> {
  modulePromise ??= import("ghostty-web").then(async (mod) => {
    await mod.init();
    return mod;
  });
  return modulePromise;
}
