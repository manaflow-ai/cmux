// A send that resumes after a wait (files read or uploaded, dictation ended, setup done) marks itself
// while it runs, so its Computer Use check holds and says why but never opens setup (CMUX-682): the key
// press that began it is long gone, and setup would spend a key pressed since. A plain function, so the
// components that use it keep compiling (the React Compiler skips a `try` without `catch`).
export function runResumed<T>(resuming: { current: boolean }, run: () => T): T {
  const was = resuming.current;
  resuming.current = true;
  try {
    return run();
  } finally {
    resuming.current = was;
  }
}

/// A submit no component started itself: dictation's auto-send, run when the dictated words land, long
/// after the key or click that stopped it (dictation.ts). The composers' holds read it as resumed.
const pageResuming = { current: false };
export function runResumedSubmit<T>(run: () => T): T {
  return runResumed(pageResuming, run);
}
export function submitResumed(): boolean {
  return pageResuming.current;
}
