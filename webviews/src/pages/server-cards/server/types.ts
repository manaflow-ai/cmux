// The Mac server's surfaces on the server card page: the menu bar panel (`#/server-panel`), Health
// (`#/server-health`) and the pairing code (`#/server-pairing`) in the menu bar item's popover, and
// the Add Server card (`#/add-server`) in the floating card panel. The app answers the ops from one
// ServerModel (ServerPageProvider.swift); the page derives every layout, button and key (model.ts).
// Times are Unix milliseconds.

export const ServerOps = {
  /** `{}` → `ServerStatus`. */
  status: "cmux.server.status",
  /** `ServerIntent` → null. The person's own click or key only. */
  send: "cmux.server.send",
  /** `{code}` → null: the Add Server code field (a complete code is looked up). */
  setCode: "cmux.server.approver.setCode",
  /** `{name}` → null: the Name field, read when Approve goes. */
  setName: "cmux.server.approver.setName",
  /** `{team}` → null: one of the found server's teams. */
  setTeam: "cmux.server.approver.setTeam",
  /** `{on}` → null: run the person's Chief on the server. The person's own click or key. */
  setRunChief: "cmux.server.approver.setRunChief",
  // No approve op: Approve and Try Again are the card panel's native control in its own footer under
  // the page (WebCardPanel's PersonControl), and only the person's click on it adds the server.
  /** `{}` → null: Cancel or Deny: the draft and the last answer go. */
  cancel: "cmux.server.approver.cancel",
  /** Stream: one empty event whenever the status may have changed; the page asks again. */
  changes: "cmux.server.changes",
} as const;

/** The routes (`#/<route>`). */
export const ServerRoutes = {
  panel: "server-panel",
  health: "server-health",
  pairing: "server-pairing",
  addServer: "add-server",
} as const;

export type ServerPlatform = "macos" | "linux" | "windows";
export type ServerRoleState = "on" | "off" | "starting" | "failed" | "unavailable";
export type AppServerState = "starting" | "running" | "draining" | "crashloop" | "stopped";
export type HealthSeverity = "info" | "warning" | "critical";

export interface ServerAppServer {
  appID: string;
  name: string;
  state: AppServerState;
  /** This host runs it (one host per team holds an app's lease). */
  holdsLease: boolean;
  durability: "zero-loss" | "bounded";
}

export interface ServerDatabase {
  app: string;
  sizeBytes: number;
  quotaBytes: number;
}

export type ServerBrowserState =
  | { state: "off" }
  | { state: "idle" }
  | { state: "running"; pages: number }
  | { state: "unavailable" };

/** A one-click fix: `needsAdmin` asks for an administrator once; `opensSettings` opens a settings pane. */
export interface HealthFix {
  title: string;
  needsAdmin: boolean;
  opensSettings: boolean;
}

/** One alert of the health reducer; the server writes title and body (they carry live numbers). */
export interface HealthAlert {
  check: string;
  severity: HealthSeverity;
  title: string;
  body: string;
  fix?: HealthFix;
  raisedAt: number;
  resolvedAt?: number;
}

export interface PairingOffer {
  /** Eight Crockford base32 symbols without the dash. */
  code: string;
  expiresAt: number;
  /** The four fingerprint words. */
  words: string[];
  /** The QR code of the offer's pairing link as a PNG data URL (dark on white). */
  qr?: string;
}

export type ServerPairingState =
  | { state: "unpaired"; offer?: PairingOffer }
  | { state: "pairing" }
  | { state: "paired"; team: string; owner: string; hostID: string };

export interface ServerDevice {
  id: string;
  name: string;
  kind: "mac" | "phone" | "web" | "cli";
  lastSeen?: number;
}

export interface ServerSnapshot {
  hostName: string;
  platform: ServerPlatform;
  enabled: boolean;
  roles: { role: string; state: ServerRoleState }[];
  terminals: number;
  appServers: ServerAppServer[];
  databases: ServerDatabase[];
  browser: ServerBrowserState;
  automations: number;
  pairing: ServerPairingState;
  devices: ServerDevice[];
  /** The checks the health role runs, in its order. */
  checks: string[];
  /** Open and recently resolved alerts, in any order. */
  alerts: HealthAlert[];
  store: { version: string; channel: string; pinned: boolean };
}

export type ServerConnection =
  | { state: "connecting" }
  | { state: "connected" }
  | { state: "unavailable"; reason: string };

export interface ChiefPlacement {
  serverName: string;
  state: "ready" | "thinking" | "notAnswering";
  lastReply?: number;
}

export interface ServerTeam {
  id: string;
  name: string;
}

/** The pending server a code points at: what the approver checks before Approve. */
export interface PairingCandidate {
  code: string;
  name: string;
  os: string;
  version: string;
  /** ISO 3166 region code (coarse location). */
  region?: string;
  words: string[];
  teams: ServerTeam[];
  /** The server can run the person's Chief. */
  isChiefBrain: boolean;
}

export type AddServerStepName =
  | "enterCode"
  | "lookingUp"
  | "codeRefused"
  | "review"
  | "approving"
  | "approveFailed"
  | "added";

export interface ServerApprover {
  /** Counts the card's openings: the page starts its own field state per opening. */
  session: number;
  step: AddServerStepName;
  candidate?: PairingCandidate;
  /** The refusal (codeRefused, approveFailed). */
  reject?: string;
  /** The added server's name. */
  added?: string;
  canApprove: boolean;
  draft: { code: string; name: string; team?: string; runChief: boolean };
}

/** Intents in flight the page marks. */
export interface ServerPending {
  switching: boolean;
  pairing: boolean;
  fixing: string[];
  revoking: string[];
}

export interface ServerStatus {
  connection: ServerConnection;
  snapshot?: ServerSnapshot;
  chief?: ChiefPlacement;
  /** The last refusal; cleared by the next intent. */
  lastReject?: string;
  pending: ServerPending;
  approver: ServerApprover;
}

export type ServerIntent =
  | { kind: "setEnabled"; on: boolean }
  | { kind: "showPairingCode" }
  | { kind: "fixCheck"; check: string }
  | { kind: "revokeDevice"; device: string };
