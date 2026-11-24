// Compressed frames from acpmux on a socket that crosses a network (Leo, 2026-11-22: "get that gui agent chat sped
// up to be nearly as fast as the terminal coming back ... the agent gui needs that too"). acpmux sends a message of
// 16 KiB or more as one Binary frame holding the zlib stream of its JSON text once the client lists "zlib" in
// `initialize` `_meta.acpmux.compression` (cmux-tui/crates/acpmux/src/frame_compress.rs); a chat's attach is
// about 75 KB of JSON and goes over in about a seventh of that. Only a page whose own WebSocket leaves this machine
// asks: the app's bridge and a loopback socket gain nothing from it.

/// The codec the page reads, as acpmux names it.
export const FRAME_CODEC = "zlib";

/// The JSON text of one message, inflated, is never more than acpmux's own per-message limit
/// (`rpc::MAX_MESSAGE_BYTES`, 31 MiB): a frame that inflates past it is refused, not held.
export const MAX_INFLATED_BYTES = 31 << 20;

const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);

/// Whether a page's own socket to `endpoint` should ask for compressed frames: a native WebSocket
/// (`acpmux-websocket`) to a host other than this machine, in an engine that can inflate zlib.
export function offersFrameCompression(transport: string | undefined, endpoint: string | undefined): boolean {
  if (transport !== "acpmux-websocket" || !endpoint) return false;
  if (typeof DecompressionStream !== "function") return false;
  let host: string;
  try {
    host = new URL(endpoint).hostname;
  } catch {
    return false;
  }
  return !LOOPBACK.has(host) && !host.startsWith("127.");
}

/// The JSON text of one Binary frame (zlib, RFC 1950: the Compression Streams "deflate" format). Rejects
/// a frame that is not zlib or inflates past `limit` bytes.
export async function inflateFrame(
  data: Blob | ArrayBuffer | ArrayBufferView,
  limit = MAX_INFLATED_BYTES,
): Promise<string> {
  const blob = data instanceof Blob ? data : new Blob([data as BlobPart]);
  const reader = blob.stream().pipeThrough(new DecompressionStream("deflate")).getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel().catch(() => undefined);
      throw new Error(`a compressed frame inflates past ${limit} bytes`);
    }
    chunks.push(value);
  }
  const text = new Uint8Array(total);
  let at = 0;
  for (const chunk of chunks) {
    text.set(chunk, at);
    at += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(text);
}

/// One socket's inbound frames in arrival order. A text frame with nothing waiting is handed on at once, as before;
/// once a Binary frame is inflating, every frame after it waits its turn, so replies never reorder.
/// Stop condition: the chain is per socket and ends with it; `onError` gets a frame that does not inflate (the
/// caller ends the connection), and nothing after it is handed on.
export class OrderedFrames {
  private tail: Promise<void> = Promise.resolve();
  private waiting = 0;
  private failed = false;

  constructor(
    private readonly deliver: (text: string) => void,
    private readonly onError: (error: unknown) => void,
  ) {}

  push(data: unknown): void {
    if (this.failed) return;
    if (typeof data === "string" && this.waiting === 0) {
      this.deliver(data);
      return;
    }
    const text =
      typeof data === "string" ? Promise.resolve(data) : inflateFrame(data as Blob | ArrayBuffer | ArrayBufferView);
    // A rejected inflate is read by the chain below, never left unhandled.
    text.catch(() => undefined);
    this.waiting += 1;
    this.tail = this.tail.then(async () => {
      try {
        const got = await text;
        if (!this.failed) this.deliver(got);
      } catch (error) {
        if (!this.failed) {
          this.failed = true;
          this.onError(error);
        }
      } finally {
        this.waiting -= 1;
      }
    });
  }

  /// Resolves once every frame pushed so far has been handed on or refused.
  drained(): Promise<void> {
    return this.tail;
  }
}
