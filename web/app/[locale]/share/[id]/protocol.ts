// Wire protocol types for the multiplayer share viewer.
// Mirrors plans/feat-multiplayer-share/DESIGN.md ("WebSocket messages").

export type ParticipantRole = "host" | "viewer";

export interface Participant {
  id: string;
  email: string;
  name: string;
  color: number;
  role: ParticipantRole;
}

export type PaneKind = "terminal" | "browser" | "textbox" | "other";

export interface PaneRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface Pane {
  id: string;
  kind: PaneKind;
  title?: string;
  rect: PaneRect;
  surfaceId?: string;
  cols?: number;
  rows?: number;
  replaySeq?: number;
  replay_b64?: string;
  url?: string;
}

export interface Workspace {
  title?: string;
  size: { width: number; height: number };
  panes: Pane[];
}

export type JoinState = "pending" | "approved" | "denied";

export interface TextboxState {
  text: string;
  selStart: number;
  selEnd: number;
  active: boolean;
}

export type ServerMessage =
  | { type: "join_state"; state: JoinState }
  | { type: "snapshot"; workspace: Workspace }
  | { type: "layout"; workspace: Workspace }
  | { type: "term"; surfaceId: string; seq: number; data_b64: string }
  | { type: "term_resize"; surfaceId: string; cols: number; rows: number }
  | ({ type: "textbox"; paneId: string } & TextboxState)
  | { type: "cursor"; participantId: string; x: number; y: number }
  | {
      type: "chat";
      participantId: string;
      text: string;
      x: number;
      y: number;
      ts: number;
    }
  | { type: "presence"; participants: Participant[] }
  | { type: "ended" };

export function parseServerMessage(raw: unknown): ServerMessage | null {
  if (typeof raw !== "string") return null;
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (
    typeof value !== "object" ||
    value === null ||
    typeof (value as { type?: unknown }).type !== "string"
  ) {
    return null;
  }
  return value as ServerMessage;
}

export function decodeBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) {
    bytes[i] = bin.charCodeAt(i);
  }
  return bytes;
}
