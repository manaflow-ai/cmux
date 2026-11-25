/** @jsxImportSource ../../../../kit/closed */
// Session Info drawn by the App (NativeSessionInfo.tsx) loads out of the chat page's first script: a
// page only needs it once the host says it draws the panel (`sessionInfoHost`, a Debug Settings toggle
// that is off by default), and then its chunk starts loading at that event (host.ts), before the
// panel's first render. A render that comes first draws nothing until the chunk lands, then the same
// mount draws it (no Suspense fallback, no remount). cmuxterm-hq finding
// 2026-11-19-agent-pane-startup-graph; test/agent-pane-startup-graph.test.ts keeps it out of pane.js.
import { useSyncExternalStore } from "react";
import type { NativeSessionInfoProps } from "./NativeSessionInfo";
import { current, subscribe } from "./nativeSessionInfoLoader";

export function LazyNativeSessionInfo(props: NativeSessionInfoProps) {
  const module = useSyncExternalStore(subscribe, current, current);
  return module ? <module.NativeSessionInfo {...props} /> : null;
}
