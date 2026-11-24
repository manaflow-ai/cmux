// A leaf apart from direct.ts, so a module that only names a session log record (peerCopy.ts,
// tailCache.ts) does not load the pane's client. The type lives in direct/records.ts.
export type { EventRecord } from "./direct/records";
