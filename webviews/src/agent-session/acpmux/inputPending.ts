/// A key or pointer event within this long counts as input pending.
export const INPUT_RECENT_MS = 50;
let lastInputAt = Number.NEGATIVE_INFINITY;
let inputListening = false;

/// Whether a key or pointer event waits for the main thread (Chromium's `isInputPending`) or one ran
/// under `INPUT_RECENT_MS` ago. Work that could wait a frame checks it so input goes first.
/// WebKit (the app's own engine) has no `isInputPending`. With only that check this answered false
/// there, so a streamed chunk's synchronous transcript pass ran ahead of every typed character:
/// WebKit composer typing under a stream measured p95 57 ms, p99 114 ms (L1), against Chromium's 17 / 20.
export function inputPending(now = performance.now()): boolean {
  listenForInput();
  const scheduling = (globalThis.navigator as { scheduling?: { isInputPending?: () => boolean } } | undefined)
    ?.scheduling;
  try {
    if (scheduling?.isInputPending?.() === true) return true;
  } catch {
    // An engine whose isInputPending throws counts on the recent-input listeners below.
  }
  return now - lastInputAt < INPUT_RECENT_MS;
}

/// The recent-input listeners: passive, capture-phase, one set per page for its life.
export function listenForInput(): void {
  if (inputListening || typeof window === "undefined" || typeof window.addEventListener !== "function") return;
  inputListening = true;
  const note = () => {
    lastInputAt = performance.now();
  };
  for (const type of ["keydown", "pointerdown", "compositionupdate", "beforeinput"]) {
    window.addEventListener(type, note, { capture: true, passive: true });
  }
}

// Listening from load, so the first key before any check already counts.
listenForInput();
