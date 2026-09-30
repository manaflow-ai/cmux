// Protocol between a mux server and a machine's link (mux/link, Rust).
// The link dials the server; the server calls allowlisted methods on it; the
// link reports agent events back. Keep in sync with link/src/protocol.rs.

import type { ID } from "./chat.ts";

export interface MachineInfo {
  /** Stable per machine, chosen by the link (hostname unless configured). */
  id: ID;
  name: string;
  os: string;
  linkVersion: string;
  acpmux: boolean;
}

export interface AgentSummary {
  sessionId: string;
  name: string;
  harness: string;
  cwd: string;
  status: string;
  preview: string | null;
  pendingPermissions: number;
  updatedAt: number;
}

/** Methods a link serves. Params and results, by method name. */
export interface LinkMethods {
  "agents.list": { params: Record<string, never>; result: { agents: AgentSummary[] } };
  "agents.harnesses": {
    params: Record<string, never>;
    result: { harnesses: string[]; defaultHarness: string | null };
  };
  /** Creates an acpmux session and queues the prompt; returns before the turn ends. */
  "agents.spawn": {
    params: { cwd: string; prompt: string; harness?: string; name?: string; policy?: string };
    result: { sessionId: string; name: string };
  };
  /** Queues a prompt on an existing session; `steer` interrupts the running turn. */
  "agents.prompt": {
    params: { session: string; text: string; steer?: boolean };
    result: { queued: true };
  };
  /** The last reply text of a session. */
  "agents.last": { params: { session: string }; result: { text: string } };
  "agents.cancel": { params: { session: string }; result: { cancelled: true } };
}

export type LinkMethod = keyof LinkMethods;

export type LinkEvent =
  | {
      kind: "turn_end";
      sessionId: string;
      name: string;
      status: string;
      stopReason?: string;
      reply: string;
    }
  | { kind: "permission"; sessionId: string; name: string; permissionId: string; title: string };

/** Link to server. */
export type LinkUpFrame =
  | { type: "hello"; machine: MachineInfo }
  | { type: "result"; id: number; ok: true; value: unknown }
  | { type: "result"; id: number; ok: false; error: string }
  | { type: "event"; event: LinkEvent };

/** Server to link. */
export type LinkDownFrame =
  | { type: "welcome"; accountId: ID }
  | { type: "call"; id: number; method: LinkMethod; params: unknown };
