// Every webviews build (each vite.config.*, whose roots sit under this directory) loads this file.
// FOCUS-RING: see scripts/postcss/focusRingGate.mjs and src/ui/focusModality.ts.
import focusRingGate from "./scripts/postcss/focusRingGate.mjs";
// HAS-LIST: see scripts/postcss/splitHasLists.mjs (WebKit restyled per key under a minifier `:is(...)`).
import splitHasLists from "./scripts/postcss/splitHasLists.mjs";

export default { plugins: [focusRingGate(), splitHasLists()] };
