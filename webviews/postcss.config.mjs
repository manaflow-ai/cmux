// Every webviews build (each vite.config.*, whose roots sit under this directory) loads this file.
// SUBJECT-BUCKETS: see scripts/postcss/subjectBuckets.mjs (test/subject-buckets.test.ts).
// FOCUS-RING: see scripts/postcss/focusRingGate.mjs and src/ui/focusModality.ts.
import focusRingGate from "./scripts/postcss/focusRingGate.mjs";
import subjectBuckets from "./scripts/postcss/subjectBuckets.mjs";

export default { plugins: [subjectBuckets(), focusRingGate()] };
