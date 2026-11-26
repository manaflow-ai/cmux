import { CmuxTimeoutError } from "cmux/raw";
import type {
  CmuxClient,
  DecodedOutputEvent,
  DecodedResizedEvent,
  DecodedVtStateEvent,
  Id,
  OverflowEvent,
} from "cmux/raw";

/**
 * One terminal's byte stream, as a web terminal renderer consumes it
 * (RFD 0083 step 4). The local WebSocket protocol implements it today
 * ({@link localWebSocketTransport}); the `cmux-remote-web` wasm client
 * implements the same shape over remote protocol v5's `process-stream`
 * service, so the renderer does not change between the two.
 */
export type TerminalStreamEvent =
  /** The whole screen, replayed: reset the emulator, size it, write `data`. */
  | { kind: "replay"; cols: number; rows: number; data: Uint8Array }
  /** PTY output, in order, after the last replay. */
  | { kind: "output"; data: Uint8Array }
  /** The stream fell behind and was dropped; open a new one to resync. */
  | { kind: "overflow" }
  /** The terminal is gone (closed, or detached by the server). */
  | { kind: "ended" };

export interface TerminalStream {
  next(): Promise<TerminalStreamEvent>;
  close(): void;
}

export interface TerminalByteTransport {
  open(surface: Id): Promise<TerminalStream>;
  input(surface: Id, text: string): Promise<void>;
  /** This viewer's size; the server answers with a `replay` at the shared size. */
  resize(surface: Id, cols: number, rows: number): Promise<void>;
  /** Drop this viewer's size report. */
  release(surface: Id): Promise<void>;
}

/** Maps one raw attach event to a stream event; null for events a byte renderer ignores. */
export function toTerminalStreamEvent(
  event: { event: string; [key: string]: unknown },
  surface: Id,
): TerminalStreamEvent | null {
  switch (event.event) {
    case "vt-state": {
      const replay = event as unknown as DecodedVtStateEvent;
      return { kind: "replay", cols: replay.cols, rows: replay.rows, data: replay.data };
    }
    case "resized": {
      const resized = event as unknown as DecodedResizedEvent;
      return { kind: "replay", cols: resized.cols, rows: resized.rows, data: resized.data };
    }
    case "output":
      return { kind: "output", data: (event as unknown as DecodedOutputEvent).data };
    case "overflow": {
      const overflow = event as unknown as OverflowEvent;
      return overflow.scope === "surface" && overflow.surface === surface ? { kind: "overflow" } : null;
    }
    case "detached":
      return { kind: "ended" };
    default:
      return null;
  }
}

/** The local WebSocket protocol's `surface.attach` byte stream as a {@link TerminalByteTransport}. */
export function localWebSocketTransport(client: CmuxClient): TerminalByteTransport {
  return {
    async open(surface) {
      const stream = await client.attachSurface(surface);
      return {
        async next() {
          for (;;) {
            let event;
            try {
              event = await stream.next();
            } catch (error) {
              // Idle terminals produce no output within the SDK's per-read timeout.
              if (error instanceof CmuxTimeoutError) continue;
              throw error;
            }
            const mapped = toTerminalStreamEvent(event as { event: string }, surface);
            if (mapped !== null) return mapped;
          }
        },
        close: () => stream.close(),
      };
    },
    input: async (surface, text) => {
      await client.send(surface, { text });
    },
    resize: async (surface, cols, rows) => {
      await client.resizeSurface(surface, cols, rows);
    },
    release: async (surface) => {
      await client.releaseSurfaceSize(surface);
    },
  };
}
