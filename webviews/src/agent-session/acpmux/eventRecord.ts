// A leaf apart from direct.ts, so a module that only names a session log record (peerCopy.ts,
// tailCache.ts) does not load the pane's client.
import type { SessionEvent } from "./protocol/generated/types";

/// A session log record (acpmux's `SessionEvent`); the pane reads `msg`, a raw JSON-RPC message
/// or acpmux's payload, loosely.
export type EventRecord = Pick<SessionEvent, "seq" | "at" | "dir" | "kind"> & {
  sessionId?: string;
  msg: Record<string, any>;
};
