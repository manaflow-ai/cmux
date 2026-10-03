// The wire contract between the page and the native host. Settings ops are the daemon's
// v2 `settings.*` operations, relayed unchanged by Swift; page ops stay in the app.

export type ManagedInfo = { source: string; reason: string };

export type ListRow = {
  key: string;
  value: unknown;
  default: unknown;
  customized: boolean;
  managed: ManagedInfo | null;
};

export type ListResult = { revision: number; rows: ListRow[] };

export type Diagnostic = { path: string | string[]; message: string };

export type SnapshotResult = {
  revision: number;
  effective: Record<string, unknown>;
  managed: Record<string, ManagedInfo>;
  diagnostics: Diagnostic[];
  schema_hash: string;
};

export type ErrorCode = "managed" | "invalid_params" | "agent_refused" | "revision_conflict" | "unavailable";

export type WireError = { code: ErrorCode | string; message: string; details?: unknown };

export type ErrorReply = { error: WireError };

export type Domains = { themes: string[]; font_families: string[]; sounds: string[] };

export type ReadyReply = {
  locale?: string | null;
  theme?: Record<string, unknown> | null;
  domains?: Partial<Domains> | null;
  initialRoute?: string | null;
};

export type NativeTarget = "cmuxJSON" | "section";

/** Every op the page sends, with its params and its successful result. */
export type Ops = {
  "settings.list": [{ section?: string }, ListResult];
  "settings.snapshot": [Record<string, never>, SnapshotResult];
  "settings.set": [{ key: string; value: unknown }, unknown];
  "settings.reset": [{ key: string }, unknown];
  "settings.reset_all": [Record<string, never>, unknown];
  preview: [{ key: string; value: unknown }, unknown];
  "preview.end": [{ key: string }, unknown];
  "native.open": [{ target: NativeTarget; section?: string }, unknown];
  "sound.play": [{ name: string }, unknown];
  ready: [Record<string, never>, ReadyReply];
};

export type OpName = keyof Ops;

export type SettingsEvent =
  | { type: "settings.changed"; revision: number; keys: string[] }
  | { type: "connection"; connected: boolean };

export interface SettingsTransport {
  request<K extends OpName>(op: K, params: Ops[K][0]): Promise<Ops[K][1] | ErrorReply>;
  subscribe(listener: (event: SettingsEvent) => void): () => void;
}

export function isErrorReply(value: unknown): value is ErrorReply {
  return typeof value === "object" && value !== null && "error" in value && typeof value.error === "object";
}
