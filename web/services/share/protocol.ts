import { MAX_TERMINAL_CELLS } from "./terminalLimits";

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

export type TerminalVtFrame = {
  readonly surfaceId: string;
  readonly generation: number;
  readonly stateSeq: number;
  readonly columns: number;
  readonly rows: number;
  readonly kind: "snapshot" | "patch";
  readonly dataB64: string;
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
  const paneIds = new Set<string>();
  const surfaceIds = new Set<string>();
  for (const value of scene.panes) {
    const pane = normalizePane(value, scene.width, scene.height);
    if (!pane || paneIds.has(pane.id)) return null;
    paneIds.add(pane.id);
    for (const surface of pane.surfaces) {
      if (surfaceIds.has(surface.id)) return null;
      surfaceIds.add(surface.id);
    }
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

export function normalizeTerminalVtFrame(value: unknown): TerminalVtFrame | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const frame = value as Record<string, unknown>;
  if (
    typeof frame.surfaceId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(frame.surfaceId) ||
    !positiveInteger(frame.generation) ||
    !positiveInteger(frame.stateSeq) ||
    !positiveInteger(frame.columns) || (frame.columns as number) > 1_000 ||
    !positiveInteger(frame.rows) || (frame.rows as number) > 1_000 ||
    (frame.columns as number) * (frame.rows as number) > MAX_TERMINAL_CELLS ||
    (frame.kind !== "snapshot" && frame.kind !== "patch") ||
    !validTerminalBase64(frame.dataB64)
  ) return null;
  return frame as unknown as TerminalVtFrame;
}

function normalizePane(value: unknown, sceneWidth: number, sceneHeight: number): WorkspacePane | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const pane = value as Record<string, unknown>;
  if (
    !shortString(pane.id, 128) ||
    !shortString(pane.selectedSurfaceId, 128) ||
    !validFrame(pane.frame, sceneWidth, sceneHeight) ||
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
  if (!surfaces.some((surface) => surface.id === pane.selectedSurfaceId)) return null;
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

function validTerminalBase64(value: unknown): value is string {
  if (typeof value !== "string" || value.length < 4 || value.length > 2_000_000 || value.length % 4 !== 0 ||
      !/^[A-Za-z0-9+/]*={0,2}$/u.test(value)) return false;
  const firstPadding = value.indexOf("=");
  if (firstPadding >= 0 && firstPadding < value.length - 2) return false;
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  const decodedBytes = value.length / 4 * 3 - padding;
  return decodedBytes > 0 && decodedBytes <= 1_500_000;
}

function validFrame(value: unknown, sceneWidth: number, sceneHeight: number): value is WorkspaceFrame {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const frame = value as Record<string, unknown>;
  return nonnegativeNumber(frame.x) && nonnegativeNumber(frame.y) &&
    positiveNumber(frame.width) && positiveNumber(frame.height) &&
    frame.x + frame.width <= sceneWidth + Number.EPSILON * Math.max(1, sceneWidth) * 16 &&
    frame.y + frame.height <= sceneHeight + Number.EPSILON * Math.max(1, sceneHeight) * 16;
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

function nonnegativeNumber(value: unknown): value is number {
  return finiteNumber(value) && value >= 0;
}

function nonnegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function positiveInteger(value: unknown): value is number {
  return nonnegativeInteger(value) && value > 0;
}
