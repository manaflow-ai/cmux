export const SHARE_PROTOCOL_VERSION = 1 as const;
export const SHARE_WEBSOCKET_PROTOCOL = "cmux-share.v1";
export const SHARE_TICKET_PROTOCOL_PREFIX = "cmux-share-ticket.";

export type ShareParticipant = {
  readonly connectionId: string;
  readonly userId: string;
  readonly displayName: string;
  readonly color: number;
  readonly role: "host" | "viewer";
};

export type ShareFrame = {
  readonly v: typeof SHARE_PROTOCOL_VERSION;
  readonly type: string;
  readonly seq: number;
  readonly payload: Record<string, unknown>;
};

export type WorkspaceFrame = {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
};

export type WorkspaceSurface = {
  readonly id: string;
  readonly title: string;
  readonly kind: "terminal" | "browser" | "textbox" | "unsupported";
  readonly docId?: string;
  readonly imageDataUrl?: string;
};

export type WorkspacePane = {
  readonly id: string;
  readonly frame: WorkspaceFrame;
  readonly selectedSurfaceId: string;
  readonly surfaces: readonly WorkspaceSurface[];
};

export type WorkspaceScene = {
  readonly workspaceId: string;
  readonly workspaceTitle: string;
  readonly layoutRevision: number;
  readonly width: number;
  readonly height: number;
  readonly panes: readonly WorkspacePane[];
};

export type TerminalStyle = {
  readonly id: number;
  readonly foreground?: string;
  readonly background?: string;
  readonly bold?: boolean;
  readonly faint?: boolean;
  readonly italic?: boolean;
  readonly underline?: boolean;
  readonly strikethrough?: boolean;
  readonly inverse?: boolean;
  readonly invisible?: boolean;
};

export type TerminalRowSpan = {
  readonly row: number;
  readonly column: number;
  readonly style_id: number;
  readonly text: string;
  readonly cell_width?: number;
};

export type TerminalGridFrame = {
  readonly format: "cmux.render-grid.v1";
  readonly surface_id: string;
  readonly state_seq: number;
  readonly columns: number;
  readonly rows: number;
  readonly full: boolean;
  readonly cleared_rows: readonly number[];
  readonly styles: readonly TerminalStyle[];
  readonly row_spans: readonly TerminalRowSpan[];
  readonly terminal_background?: string;
  readonly terminal_foreground?: string;
  readonly cursor?: {
    readonly row: number;
    readonly column: number;
    readonly visible?: boolean;
    readonly style?: "block" | "bar" | "underline" | "block_hollow";
  };
};

export type ShareChatMessage = {
  readonly id: string;
  readonly userId: string;
  readonly displayName: string;
  readonly color: number;
  readonly text: string;
  readonly createdAt: number;
};

export type SharePointer = {
  readonly participant: ShareParticipant;
  readonly x: number;
  readonly y: number;
  readonly layoutRevision: number;
  readonly targetId?: string;
};

export type TextSelectionAwareness = {
  readonly participant: ShareParticipant;
  readonly docId: string;
  readonly anchorUTF16: number;
  readonly headUTF16: number;
};

export function parseShareFrame(value: unknown): ShareFrame | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  if (
    candidate.v !== SHARE_PROTOCOL_VERSION ||
    typeof candidate.type !== "string" ||
    !Number.isSafeInteger(candidate.seq) ||
    (candidate.seq as number) < 0 ||
    !candidate.payload ||
    typeof candidate.payload !== "object" ||
    Array.isArray(candidate.payload)
  ) return null;
  return candidate as ShareFrame;
}

export function normalizeWorkspaceScene(value: unknown): WorkspaceScene | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const scene = value as Record<string, unknown>;
  if (
    !shortString(scene.workspaceId, 128) ||
    !shortString(scene.workspaceTitle, 160) ||
    !positiveNumber(scene.width) ||
    !positiveNumber(scene.height) ||
    !nonnegativeInteger(scene.layoutRevision) ||
    !Array.isArray(scene.panes) ||
    scene.panes.length > 64
  ) return null;
  const panes: WorkspacePane[] = [];
  for (const value of scene.panes) {
    const pane = normalizePane(value);
    if (!pane) return null;
    panes.push(pane);
  }
  return {
    workspaceId: scene.workspaceId,
    workspaceTitle: scene.workspaceTitle,
    layoutRevision: scene.layoutRevision,
    width: scene.width,
    height: scene.height,
    panes,
  };
}

export function normalizeTerminalFrame(value: unknown): TerminalGridFrame | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const frame = value as Record<string, unknown>;
  if (
    frame.format !== "cmux.render-grid.v1" ||
    !shortString(frame.surface_id, 128) ||
    !positiveInteger(frame.columns) || (frame.columns as number) > 1_000 ||
    !positiveInteger(frame.rows) || (frame.rows as number) > 1_000 ||
    !nonnegativeInteger(frame.state_seq) ||
    typeof frame.full !== "boolean" ||
    !Array.isArray(frame.cleared_rows) ||
    !Array.isArray(frame.styles) ||
    !Array.isArray(frame.row_spans) ||
    frame.styles.length > 2_048 ||
    frame.row_spans.length > 100_000
  ) return null;
  return frame as unknown as TerminalGridFrame;
}

function normalizePane(value: unknown): WorkspacePane | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const pane = value as Record<string, unknown>;
  if (
    !shortString(pane.id, 128) ||
    !shortString(pane.selectedSurfaceId, 128) ||
    !validFrame(pane.frame) ||
    !Array.isArray(pane.surfaces) ||
    pane.surfaces.length < 1 ||
    pane.surfaces.length > 128
  ) return null;
  const surfaces: WorkspaceSurface[] = [];
  for (const value of pane.surfaces) {
    const surface = normalizeSurface(value);
    if (!surface) return null;
    surfaces.push(surface);
  }
  return {
    id: pane.id,
    frame: pane.frame,
    selectedSurfaceId: pane.selectedSurfaceId,
    surfaces,
  };
}

function normalizeSurface(value: unknown): WorkspaceSurface | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const surface = value as Record<string, unknown>;
  if (
    !shortString(surface.id, 128) ||
    !shortString(surface.title, 300) ||
    !["terminal", "browser", "textbox", "unsupported"].includes(String(surface.kind)) ||
    (surface.docId !== undefined && !shortString(surface.docId, 128)) ||
    (surface.imageDataUrl !== undefined && !validJPEGDataURL(surface.imageDataUrl))
  ) return null;
  return surface as WorkspaceSurface;
}

function validJPEGDataURL(value: unknown): value is string {
  return typeof value === "string" && value.length <= 1_500_000 &&
    /^data:image\/jpeg;base64,[A-Za-z0-9+/]+={0,2}$/u.test(value);
}

function validFrame(value: unknown): value is WorkspaceFrame {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const frame = value as Record<string, unknown>;
  return finiteNumber(frame.x) && finiteNumber(frame.y) && positiveNumber(frame.width) && positiveNumber(frame.height);
}

function shortString(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function finiteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function positiveNumber(value: unknown): value is number {
  return finiteNumber(value) && value > 0;
}

function nonnegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function positiveInteger(value: unknown): value is number {
  return nonnegativeInteger(value) && value > 0;
}
