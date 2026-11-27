// Local-first intents for pages (plans/cmux-next/zero-latency.md). Public API:
//   IntentStore, defineIntent, isOpid and their types (store.ts);
//   useIntentState, useIntentMeta, useIntent (react.ts);
//   PrefetchCache (prefetch.ts, rule f); afterPaint, runChunked (schedule.ts, rule g).
// Keep it small and stable: other lanes (the ACP harness switch, the acpmux adapters) build on it.
export {
  IntentStore,
  defineIntent,
  isOpid,
  type IntentError,
  type IntentKind,
  type IntentMeta,
  type IntentOutcome,
  type IntentPhase,
  type IntentSender,
  type IntentStoreOptions,
  type IntentTrace,
  type IntentTraceType,
  type PendingIntent,
  type ResourceStatus,
} from "./store";
export { useIntent, useIntentMeta, useIntentState } from "./react";
export { PrefetchCache, type PrefetchCacheOptions } from "./prefetch";
export { afterPaint, runChunked, type ChunkedOptions } from "./schedule";
