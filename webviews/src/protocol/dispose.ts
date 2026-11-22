// `using` support. Bun and current Chromium define Symbol.dispose; older WebKit does not.
// Falling back to the registered symbol keeps the method under a real symbol key, so
// explicit `release()`/`unsubscribe()` always works and `using` works where the engine has it.
export const disposeSymbol: typeof Symbol.dispose =
  typeof Symbol.dispose === "symbol" ? Symbol.dispose : (Symbol.for("Symbol.dispose") as typeof Symbol.dispose);
