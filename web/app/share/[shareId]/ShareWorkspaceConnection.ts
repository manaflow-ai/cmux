"use client";

import {
  normalizeTerminalVtFrame,
  normalizeWorkspaceScene,
  parseShareFrame,
  type ShareChatMessage,
  type ShareParticipant,
  type SharePointer,
  type TerminalVtFrame,
  type TextSelectionAwareness,
  type WorkspaceScene,
} from "../../../services/share/protocol";
import {
  GhosttyTerminalRenderer,
  type RenderedGhosttyTerminal,
  type TerminalApplyResult,
} from "../../../services/share/ghosttyTerminal";
import {
  ReplicatedTextDocument,
  parseTextDocumentSnapshot,
  parseTextOperation,
  type TextCompositionSnapshot,
  type TextDocumentView,
} from "../../../services/share/textDocument";
import {
  terminalCommandsFromText,
  terminalInputPayload,
  type TerminalInputCommand,
} from "../../../services/share/terminalInput";

export type ShareConnectionStatus =
  | "connecting"
  | "pending"
  | "approved"
  | "denied"
  | "ended"
  | "reconnecting"
  | "error";

export type ShareWorkspaceViewState = {
  readonly status: ShareConnectionStatus;
  readonly scene: WorkspaceScene | null;
  readonly terminals: ReadonlyMap<string, RenderedGhosttyTerminal>;
  readonly participants: ReadonlyMap<string, ShareParticipant>;
  readonly pointers: ReadonlyMap<string, SharePointer>;
  readonly chat: readonly ShareChatMessage[];
  readonly documents: ReadonlyMap<string, TextDocumentView>;
  readonly selections: ReadonlyMap<string, TextSelectionAwareness>;
};

export const initialShareWorkspaceViewState: ShareWorkspaceViewState = {
  status: "connecting",
  scene: null,
  terminals: new Map(),
  participants: new Map(),
  pointers: new Map(),
  chat: [],
  documents: new Map(),
  selections: new Map(),
};

type TicketResponse = {
  readonly socketUrl: string;
  readonly protocols: readonly string[];
  readonly expiresAt: number;
};

export class ShareWorkspaceConnection {
  private clientId: string | null = null;
  private readonly documents = new Map<string, ReplicatedTextDocument>();
  private readonly compositions = new Map<string, TextCompositionSnapshot>();
  private readonly terminalRenderer = new GhosttyTerminalRenderer();
  private terminalSurfaceIds: ReadonlySet<string> = new Set();
  private terminalInputSurfaceIds: ReadonlySet<string> = new Set();
  private state = initialShareWorkspaceViewState;
  private socket: WebSocket | null = null;
  private abortController: AbortController | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private disposed = false;
  private clientSeq = 0;
  private operationCounter = 0;
  private retryCount = 0;
  private lastServerSeq = -1;

  constructor(
    private readonly shareId: string,
    private readonly onState: (state: ShareWorkspaceViewState) => void,
  ) {
    void this.connect();
  }

  dispose(): void {
    this.disposed = true;
    this.abortController?.abort();
    this.abortController = null;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    this.socket?.close(1000, "viewer_closed");
    this.socket = null;
    this.terminalRenderer.dispose();
  }

  pointer(x: number, y: number, layoutRevision: number, targetId?: string): void {
    this.send("presence.pointer", { x, y, layoutRevision, ...(targetId ? { targetId } : {}) });
  }

  chat(text: string): void {
    const normalized = text.trim();
    if (normalized) this.send("chat.message", { text: normalized });
  }

  terminalText(surfaceId: string, text: string): void {
    for (const command of terminalCommandsFromText(text)) this.terminalInput(surfaceId, command);
  }

  terminalInput(surfaceId: string, command: TerminalInputCommand): void {
    const scene = this.state.scene;
    if (!scene || !this.terminalInputSurfaceIds.has(surfaceId)) return;
    const payload = terminalInputPayload(surfaceId, scene.layoutRevision, command);
    if (payload) this.send("terminal.input", payload);
  }

  selection(docId: string, anchorUTF16: number, headUTF16: number): void {
    this.send("textbox.selection", { docId, anchorUTF16, headUTF16 });
  }

  changeText(docId: string, nextText: string): void {
    const document = this.documents.get(docId);
    if (!document || !this.clientId) return;
    const operations = document.localChange(nextText, this.clientId, () => ++this.operationCounter);
    if (operations.length === 0) return;
    this.publishDocuments();
    for (const operation of operations) this.send("textbox.operation", { operation });
  }

  beginTextComposition(docId: string): void {
    const document = this.documents.get(docId);
    if (document) this.compositions.set(docId, document.beginComposition());
  }

  commitTextComposition(docId: string, nextText: string): void {
    const document = this.documents.get(docId);
    const composition = this.compositions.get(docId);
    this.compositions.delete(docId);
    if (!document || !composition || !this.clientId) {
      this.changeText(docId, nextText);
      return;
    }
    const operations = document.localChangeFrom(
      composition,
      nextText,
      this.clientId,
      () => ++this.operationCounter,
    );
    if (operations.length === 0) return;
    this.publishDocuments();
    for (const operation of operations) this.send("textbox.operation", { operation });
  }

  private async connect(): Promise<void> {
    if (this.disposed) return;
    this.abortController?.abort();
    const abortController = new AbortController();
    this.abortController = abortController;
    this.patch({ status: this.retryCount > 0 ? "reconnecting" : "connecting" });
    try {
      const response = await fetch(`/api/share/${encodeURIComponent(this.shareId)}/ticket`, {
        method: "POST",
        credentials: "same-origin",
        headers: { "content-type": "application/json" },
        body: "{}",
        cache: "no-store",
        signal: abortController.signal,
      });
      if (response.status === 401) {
        window.location.reload();
        return;
      }
      if (!response.ok) throw new Error("ticket_unavailable");
      const ticket = normalizeTicket(await response.json());
      if (!ticket) throw new Error("invalid_ticket_response");
      this.openSocket(ticket);
    } catch (error) {
      if (!this.disposed && !(error instanceof DOMException && error.name === "AbortError")) this.scheduleReconnect();
    }
  }

  private openSocket(ticket: TicketResponse): void {
    if (this.disposed) return;
    const socket = new WebSocket(ticket.socketUrl, [...ticket.protocols]);
    this.socket = socket;
    socket.onopen = () => {
      this.retryCount = 0;
      this.lastServerSeq = -1;
    };
    socket.onmessage = (event) => this.receive(event.data);
    socket.onerror = () => socket.close();
    socket.onclose = () => {
      if (this.socket === socket) this.socket = null;
      if (!this.disposed && !["denied", "ended"].includes(this.state.status)) this.scheduleReconnect();
    };
  }

  private receive(raw: unknown): void {
    if (typeof raw !== "string" || raw.length > 2 * 1_024 * 1_024) return;
    let decoded: unknown;
    try {
      decoded = JSON.parse(raw);
    } catch {
      return;
    }
    const frame = parseShareFrame(decoded);
    if (!frame || frame.seq <= this.lastServerSeq) return;
    this.lastServerSeq = frame.seq;
    const payload = frame.payload;

    if (frame.type === "access.status") {
      const status = payload.status;
      const participant = normalizeParticipant(payload.participant);
      if (participant?.role === "viewer") {
        this.clientId = participant.connectionId;
        const participants = new Map(this.state.participants);
        participants.set(participant.connectionId, participant);
        this.patch({ participants });
      }
      if (status === "pending" || status === "approved" || status === "denied") this.patch({ status });
      return;
    }
    if (frame.type === "share.ended") {
      this.patch({ status: "ended" });
      this.socket?.close(4000, "share_ended");
      return;
    }
    if (frame.type === "workspace.snapshot" || frame.type === "workspace.layout") {
      const scene = normalizeWorkspaceScene(payload.scene ?? payload);
      if (scene) {
        const terminalSurfaceIds = terminalVtSurfaceIdsForScene(scene);
        this.terminalSurfaceIds = terminalSurfaceIds;
        this.terminalInputSurfaceIds = terminalInputSurfaceIdsForScene(scene);
        void this.terminalRenderer.retainSurfaces(terminalSurfaceIds);
        const terminals = new Map(
          [...this.state.terminals].filter(([surfaceId]) => terminalSurfaceIds.has(surfaceId)),
        );
        this.patch({ scene, status: "approved", terminals });
      }
      if (Array.isArray(payload.terminalFrames)) {
        for (const value of payload.terminalFrames) this.applyTerminal(value);
      }
      if (Array.isArray(payload.textDocuments)) {
        for (const value of payload.textDocuments) this.installDocument(value);
      }
      return;
    }
    if (frame.type === "terminal.vt") {
      this.applyTerminal(payload.frame ?? payload);
      return;
    }
    if (frame.type === "panel.frame") {
      this.applyPanelFrame(payload);
      return;
    }
    if (frame.type === "textbox.document") {
      this.installDocument(payload.document ?? payload);
      return;
    }
    if (frame.type === "textbox.operation") {
      this.applyTextOperation(payload.operation, payload.revision);
      return;
    }
    if (frame.type === "textbox.selection") {
      const selection = normalizeSelection(payload);
      if (selection) {
        const selections = new Map(this.state.selections);
        selections.set(selection.participant.connectionId, selection);
        this.patch({ selections });
      }
      return;
    }
    if (frame.type === "presence.snapshot" && Array.isArray(payload.participants)) {
      const participants = new Map<string, ShareParticipant>();
      for (const value of payload.participants) {
        const participant = normalizeParticipant(value);
        if (participant) participants.set(participant.connectionId, participant);
      }
      this.patch({ participants });
      return;
    }
    if (frame.type === "presence.joined") {
      const participant = normalizeParticipant(payload.participant);
      if (participant) {
        const participants = new Map(this.state.participants);
        participants.set(participant.connectionId, participant);
        this.patch({ participants });
      }
      return;
    }
    if (frame.type === "presence.left") {
      const participant = normalizeParticipant(payload.participant);
      if (participant) {
        const participants = new Map(this.state.participants);
        const pointers = new Map(this.state.pointers);
        const selections = new Map(this.state.selections);
        participants.delete(participant.connectionId);
        pointers.delete(participant.connectionId);
        selections.delete(participant.connectionId);
        this.patch({ participants, pointers, selections });
      }
      return;
    }
    if (frame.type === "presence.pointer") {
      const pointer = normalizePointer(payload);
      if (pointer && pointer.layoutRevision === this.state.scene?.layoutRevision) {
        const pointers = new Map(this.state.pointers);
        const participants = new Map(this.state.participants);
        pointers.set(pointer.participant.connectionId, pointer);
        participants.set(pointer.participant.connectionId, pointer.participant);
        this.patch({ pointers, participants });
      }
      return;
    }
    if (frame.type === "chat.snapshot" && Array.isArray(payload.messages)) {
      this.patch({ chat: payload.messages.map(normalizeChat).filter((value): value is ShareChatMessage => !!value) });
      return;
    }
    if (frame.type === "chat.message") {
      const message = normalizeChat(payload);
      if (message) this.patch({ chat: [...this.state.chat, message].slice(-50) });
    }
  }

  private applyTerminal(value: unknown): void {
    const frame = normalizeTerminalVtFrame(value);
    if (!frame) return;
    const application = applyTerminalFrameInScene(this.terminalRenderer, this.terminalSurfaceIds, frame);
    if (!application) return;
    void application.then((result) => {
      if (this.disposed) return;
      if (result.status === "resync") {
        this.send("workspace.resync.request", { reason: "terminal_sequence" });
        return;
      }
      if (result.status !== "rendered") return;
      if (!this.terminalSurfaceIds.has(result.terminal.surfaceId)) return;
      const terminals = new Map(this.state.terminals);
      terminals.set(result.terminal.surfaceId, result.terminal);
      this.patch({ terminals });
    });
  }

  private installDocument(value: unknown): void {
    const snapshot = parseTextDocumentSnapshot(value);
    if (!snapshot) return;
    this.documents.set(snapshot.docId, new ReplicatedTextDocument(snapshot));
    this.publishDocuments();
  }

  private applyPanelFrame(payload: Record<string, unknown>): void {
    if (
      !this.state.scene ||
      typeof payload.surfaceId !== "string" ||
      typeof payload.imageDataUrl !== "string" ||
      !isJPEGDataURL(payload.imageDataUrl)
    ) return;
    let changed = false;
    const panes = this.state.scene.panes.map((pane) => ({
      ...pane,
      surfaces: pane.surfaces.map((surface) => {
        if (surface.id !== payload.surfaceId || surface.kind !== "browser") return surface;
        changed = true;
        return { ...surface, imageDataUrl: payload.imageDataUrl as string };
      }),
    }));
    if (changed) this.patch({ scene: { ...this.state.scene, panes } });
  }

  private applyTextOperation(value: unknown, revision: unknown): void {
    const operation = parseTextOperation(value);
    if (!operation) return;
    const document = this.documents.get(operation.docId);
    if (!document) {
      this.send("workspace.resync.request", { reason: "textbox_document" });
      return;
    }
    document.apply(operation, typeof revision === "number" ? revision : undefined);
    this.publishDocuments();
  }

  private publishDocuments(): void {
    this.patch({ documents: new Map([...this.documents].map(([id, document]) => [id, document.view()])) });
  }

  private send(type: string, payload: Record<string, unknown>): void {
    if (this.state.status !== "approved" || this.socket?.readyState !== WebSocket.OPEN) return;
    this.socket.send(JSON.stringify({ v: 1, type, seq: ++this.clientSeq, payload }));
  }

  private scheduleReconnect(): void {
    if (this.disposed || this.retryTimer) return;
    this.retryCount += 1;
    if (this.retryCount > 8) {
      this.patch({ status: "error" });
      return;
    }
    this.patch({ status: "reconnecting" });
    const delay = Math.min(8_000, 500 * 2 ** (this.retryCount - 1));
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.connect();
    }, delay);
  }

  private patch(patch: Partial<ShareWorkspaceViewState>): void {
    this.state = { ...this.state, ...patch };
    this.onState(this.state);
  }
}

export function applyTerminalFrameInScene(
  renderer: Pick<GhosttyTerminalRenderer, "apply">,
  terminalSurfaceIds: ReadonlySet<string>,
  frame: TerminalVtFrame,
): Promise<TerminalApplyResult> | null {
  return terminalSurfaceIds.has(frame.surfaceId) ? renderer.apply(frame) : null;
}

export function terminalVtSurfaceIdsForScene(scene: WorkspaceScene): ReadonlySet<string> {
  return new Set(scene.panes.flatMap((pane) => pane.surfaces
    .filter((surface) => surface.kind === "terminal" || surface.kind === "textbox")
    .map((surface) => surface.id)));
}

export function terminalInputSurfaceIdsForScene(scene: WorkspaceScene): ReadonlySet<string> {
  return new Set(scene.panes.flatMap((pane) => {
    const selected = pane.surfaces.find((surface) => surface.id === pane.selectedSurfaceId);
    return selected && (selected.kind === "terminal" || selected.kind === "textbox") ? [selected.id] : [];
  }));
}

function normalizeTicket(value: unknown): TicketResponse | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const ticket = value as Record<string, unknown>;
  if (
    typeof ticket.socketUrl !== "string" || !/^wss?:\/\//u.test(ticket.socketUrl) ||
    !Array.isArray(ticket.protocols) || ticket.protocols.length !== 2 ||
    !ticket.protocols.every((protocol) => typeof protocol === "string" && protocol.length > 0 && protocol.length < 8_192) ||
    typeof ticket.expiresAt !== "number"
  ) return null;
  return ticket as TicketResponse;
}

function normalizeParticipant(value: unknown): ShareParticipant | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const participant = value as Record<string, unknown>;
  return (
    typeof participant.connectionId === "string" &&
    typeof participant.userId === "string" &&
    typeof participant.displayName === "string" &&
    typeof participant.color === "number" &&
    (participant.role === "host" || participant.role === "viewer")
  ) ? participant as ShareParticipant : null;
}

function normalizePointer(value: Record<string, unknown>): SharePointer | null {
  const participant = normalizeParticipant(value.participant);
  return participant && ratio(value.x) && ratio(value.y) && Number.isSafeInteger(value.layoutRevision)
    ? { ...value, participant } as SharePointer
    : null;
}

function normalizeSelection(value: Record<string, unknown>): TextSelectionAwareness | null {
  const participant = normalizeParticipant(value.participant);
  return participant && typeof value.docId === "string" &&
    nonnegativeInteger(value.anchorUTF16) && nonnegativeInteger(value.headUTF16)
    ? { ...value, participant } as TextSelectionAwareness
    : null;
}

function normalizeChat(value: unknown): ShareChatMessage | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const message = value as Record<string, unknown>;
  return typeof message.id === "string" && typeof message.userId === "string" &&
    typeof message.displayName === "string" && typeof message.text === "string" &&
    typeof message.color === "number" && typeof message.createdAt === "number"
    ? message as ShareChatMessage
    : null;
}

function ratio(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}

function nonnegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isJPEGDataURL(value: string): boolean {
  return value.length <= 1_500_000 && /^data:image\/jpeg;base64,[A-Za-z0-9+/]+={0,2}$/u.test(value);
}
