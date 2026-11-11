// Test seam for module-level stores. bun runs every test file in one process with one module cache,
// so a store one file filled is the next file's starting state. A store hands `onTestReset` the
// function that puts it back to a fresh page's state (and lets go of what it holds: a listener on an
// old window, a cache); the test setup (test/support/leakDetector.ts) runs every registered reset
// after each test file, before it checks what the file left behind. Outside tests no registry is
// installed, so registering does nothing.
const REGISTRY = Symbol.for("cmux.testResets");

/** Registers `reset` to run after each test file; does nothing outside tests. */
export function onTestReset(reset: () => void): void {
  (globalThis as { [REGISTRY]?: (() => void)[] })[REGISTRY]?.push(reset);
}
