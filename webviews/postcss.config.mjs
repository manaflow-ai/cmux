// Every webviews build (each vite.config.*, whose roots sit under this directory) loads this file.
// FOCUS-RING: see scripts/postcss/focusRingGate.mjs and src/ui/focusModality.ts.
import focusRingGate from "./scripts/postcss/focusRingGate.mjs";

export default { plugins: [focusRingGate()] };
