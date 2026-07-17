"use client";

import { useEffect, useRef, useState } from "react";
import type { ChatEntry } from "./chat-panel";
import type { CursorBubble, RemoteCursor } from "./cursor-layer";
import {
  decodeBase64,
  parseServerMessage,
  type Participant,
  type TextboxState,
  type Workspace,
} from "./protocol";
import { SurfaceStore } from "./surface-store";

export type ShareStatus =
  | "connecting"
  | "pending"
  | "denied"
  | "ended"
  | "live";

export interface ShareState {
  status: ShareStatus;
  workspace: Workspace | null;
  participants: Participant[];
  cursors: RemoteCursor[];
  bubbles: CursorBubble[];
  chatEntries: ChatEntry[];
  textboxes: Map<string, TextboxState>;
}

export interface ShareActions {
  sendCursor: (x: number, y: number) => void;
  sendChat: (text: string, x: number, y: number) => void;
}

const BUBBLE_LIFETIME_MS = 6000;
const RECONNECT_DELAY_MS = 2000;
const MAX_RECONNECT_ATTEMPTS = 5;
const CURSOR_SENDS_PER_SECOND = 30;

let nextEntryId = 1;

/**
 * Throttles cursor broadcasts to ~30/s using requestAnimationFrame
 * gating. Defined at module scope so its methods never run during
 * render (react-hooks/purity).
 */
class CursorThrottle {
  private lastSend = 0;
  private frame: number | null = null;
  private pending: { x: number; y: number } | null = null;

  constructor(private readonly emit: (x: number, y: number) => void) {}

  push(x: number, y: number): void {
    this.pending = { x, y };
    this.frame ??= requestAnimationFrame(this.flush);
  }

  private flush = (): void => {
    this.frame = null;
    if (!this.pending) return;
    const now = performance.now();
    if (now - this.lastSend < 1000 / CURSOR_SENDS_PER_SECOND) {
      this.frame = requestAnimationFrame(this.flush);
      return;
    }
    const { x, y } = this.pending;
    this.pending = null;
    this.lastSend = now;
    this.emit(x, y);
  };
}

export function buildShareWsUrl(
  wsBase: string,
  shareId: string,
  accessToken: string,
): string {
  const base = wsBase.replace(/\/$/, "");
  const wsScheme = base
    .replace(/^https:/, "wss:")
    .replace(/^http:/, "ws:");
  const url = new URL(`${wsScheme}/v1/share/${shareId}/ws`);
  url.searchParams.set("access_token", accessToken);
  return url.toString();
}

/**
 * Owns the share WebSocket for the component's lifetime. The single
 * effect covers connect/reconnect/teardown; everything else flows
 * through state updates and the returned actions.
 */
export function useShareSocket({
  shareId,
  wsBase,
  accessToken,
  store,
}: {
  shareId: string;
  wsBase: string;
  accessToken: string | null;
  store: SurfaceStore;
}): ShareState & ShareActions {
  const [status, setStatus] = useState<ShareStatus>("connecting");
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [participants, setParticipants] = useState<Participant[]>([]);
  const [cursors, setCursors] = useState<RemoteCursor[]>([]);
  const [bubbles, setBubbles] = useState<CursorBubble[]>([]);
  const [chatEntries, setChatEntries] = useState<ChatEntry[]>([]);
  const [textboxes, setTextboxes] = useState<Map<string, TextboxState>>(
    () => new Map(),
  );

  const socketRef = useRef<WebSocket | null>(null);
  const cursorThrottleRef = useRef<CursorThrottle | null>(null);

  useEffect(() => {
    if (!accessToken) return;

    let disposed = false;
    let attempts = 0;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    const bubbleTimers = new Set<ReturnType<typeof setTimeout>>();

    const handleMessage = (event: MessageEvent) => {
      const message = parseServerMessage(event.data);
      if (!message) return;
      switch (message.type) {
        case "join_state":
          if (message.state === "pending") setStatus("pending");
          else if (message.state === "denied") setStatus("denied");
          else setStatus("live");
          break;
        case "snapshot": {
          store.reset();
          for (const pane of message.workspace.panes) {
            if (pane.kind === "terminal" && pane.surfaceId && pane.replay_b64) {
              store.applySnapshot(
                pane.surfaceId,
                decodeBase64(pane.replay_b64),
                pane.replaySeq,
              );
            }
          }
          setWorkspace(message.workspace);
          setStatus("live");
          break;
        }
        case "layout":
          setWorkspace(message.workspace);
          break;
        case "term":
          store.pushChunk(
            message.surfaceId,
            message.seq,
            decodeBase64(message.data_b64),
          );
          break;
        case "term_resize":
          store.pushResize(message.surfaceId, message.cols, message.rows);
          break;
        case "textbox":
          setTextboxes((prev) => {
            const next = new Map(prev);
            next.set(message.paneId, {
              text: message.text,
              selStart: message.selStart,
              selEnd: message.selEnd,
              active: message.active,
            });
            return next;
          });
          break;
        case "cursor":
          setCursors((prev) => {
            const next = prev.filter(
              (c) => c.participantId !== message.participantId,
            );
            next.push({
              participantId: message.participantId,
              x: message.x,
              y: message.y,
            });
            return next;
          });
          break;
        case "chat": {
          const entryId = nextEntryId++;
          setChatEntries((prev) =>
            [
              ...prev,
              {
                id: entryId,
                participantId: message.participantId,
                text: message.text,
                ts: message.ts,
              },
            ].slice(-200),
          );
          setBubbles((prev) => [
            ...prev,
            {
              id: entryId,
              participantId: message.participantId,
              text: message.text,
            },
          ]);
          const timer = setTimeout(() => {
            bubbleTimers.delete(timer);
            setBubbles((prev) => prev.filter((b) => b.id !== entryId));
          }, BUBBLE_LIFETIME_MS);
          bubbleTimers.add(timer);
          break;
        }
        case "presence":
          setParticipants(message.participants);
          setCursors((prev) =>
            prev.filter((c) =>
              message.participants.some((p) => p.id === c.participantId),
            ),
          );
          break;
        case "ended":
          setStatus("ended");
          break;
      }
    };

    const connect = () => {
      if (disposed) return;
      setStatus((prev) =>
        prev === "ended" || prev === "denied" ? prev : "connecting",
      );
      const socket = new WebSocket(
        buildShareWsUrl(wsBase, shareId, accessToken),
      );
      socketRef.current = socket;
      socket.onopen = () => {
        attempts = 0;
      };
      socket.onmessage = handleMessage;
      socket.onclose = () => {
        if (disposed || socketRef.current !== socket) return;
        socketRef.current = null;
        setStatus((prev) => {
          if (prev === "ended" || prev === "denied") return prev;
          if (attempts < MAX_RECONNECT_ATTEMPTS) {
            attempts += 1;
            reconnectTimer = setTimeout(connect, RECONNECT_DELAY_MS);
            return "connecting";
          }
          return "ended";
        });
      };
    };

    connect();

    return () => {
      disposed = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      for (const timer of bubbleTimers) clearTimeout(timer);
      const socket = socketRef.current;
      socketRef.current = null;
      socket?.close();
      store.reset();
    };
  }, [shareId, wsBase, accessToken, store]);

  const sendJson = (payload: object) => {
    const socket = socketRef.current;
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(payload));
    }
  };

  const sendCursor = (x: number, y: number) => {
    cursorThrottleRef.current ??= new CursorThrottle((cx, cy) => {
      const socket = socketRef.current;
      if (socket && socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ type: "cursor", x: cx, y: cy }));
      }
    });
    cursorThrottleRef.current.push(x, y);
  };

  const sendChat = (text: string, x: number, y: number) => {
    sendJson({ type: "chat", text, x, y });
  };

  return {
    status,
    workspace,
    participants,
    cursors,
    bubbles,
    chatEntries,
    textboxes,
    sendCursor,
    sendChat,
  };
}
