import { webcrypto } from "node:crypto";

// Ensure Web Crypto API is available (crypto.subtle) in Node.
const needsPolyfill =
  typeof (globalThis as unknown as { crypto?: Crypto }).crypto ===
    "undefined" ||
  typeof (globalThis as unknown as { crypto?: Crypto }).crypto?.subtle ===
    "undefined";

if (needsPolyfill) {
  Object.defineProperty(globalThis, "crypto", {
    value: webcrypto,
    configurable: true,
  });
}

// Minimal env needed by modules importing "_shared/convex-env"
// Set safe defaults for tests if not already provided.
if (!process.env.STACK_WEBHOOK_SECRET)
  process.env.STACK_WEBHOOK_SECRET = "test-stack-secret";
if (!process.env.BASE_APP_URL)
  process.env.BASE_APP_URL = "http://localhost:5173";
if (!process.env.INSTALL_STATE_SECRET)
  process.env.INSTALL_STATE_SECRET = "test-install-secret";
