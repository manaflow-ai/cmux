// The native transcript's Worker (RFD 0121, "a native Rust transcript, first read-only behind a flag"):
// it dials the daemon itself, hands every socket message to the Rust transcript (cmux-tui crate
// cmux-transcript-view, built to transcript_view.wasm), and paints the lines Rust laid out onto the
// canvas the page gave it, on this Worker's own frames. Nothing here waits on the page's main thread:
// Leo, "Why should non visible thing even affect the renderer thread anyways?"
//
// This file only moves bytes and draws: parsing, row shaping, wrapping and the viewport's layout are
// Rust (src/lib.rs there). NativeTranscript.tsx starts it and says the viewport's size.

/** What the page sends: first the canvas and the socket, then each new viewport size. */
export type NativeTranscriptCommand =
  | {
      type: "start";
      canvas: OffscreenCanvas;
      endpoint: string;
      protocols?: string[];
      sessionId: string;
      font: string;
      lineHeight: number;
      colors: { text: string; muted: string; background: string };
      tally: boolean;
    }
  | { type: "view"; width: number; height: number; dpr: number };

type Exports = {
  memory: WebAssembly.Memory;
  tv_alloc(len: number): number;
  tv_message(ptr: number, len: number, cap: number): number;
  tv_advance(ptr: number, count: number, cap: number, other: number): void;
  tv_view(width: number, height: number, lineHeight: number, gap: number, pad: number): void;
  tv_layout(): number;
  tv_text_ptr(): number;
  tv_text_len(): number;
  tv_lines_ptr(): number;
};

/** frameTally.ts's bucket width and count (frame_tally.rs refuses any other width). */
const BUCKET_MS = 0.1;
const BUCKETS = 1000;
const FLUSH_MS = 5_000;
/** How long after the last message the Worker keeps drawing frames (and counting them). */
const BUSY_MS = 1_000;
/** Rust's Style: User, Reply, Quiet, Thought, Tool. */
const USER = 0;
const REPLY = 1;

const scope = self as unknown as {
  onmessage: ((event: MessageEvent<NativeTranscriptCommand>) => void) | null;
  requestAnimationFrame(callback: (at: number) => void): number;
};

const encoder = new TextEncoder();
const decoder = new TextDecoder();
let wasm: Exports | undefined;
let context: OffscreenCanvasRenderingContext2D | null = null;
let start: Extract<NativeTranscriptCommand, { type: "start" }> | undefined;
let view = { width: 0, height: 0, dpr: 1 };
let dirty = false;
let lastNews = 0;
let looping = false;
let lastFrame = 0;
let counts = new Map<number, number>();
let socket: WebSocket | undefined;
let nextId = 1;

function write(bytes: Uint8Array): [number, number] {
  const cap = Math.max(1, bytes.length);
  const ptr = wasm!.tv_alloc(cap);
  new Uint8Array(wasm!.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, cap];
}

function feed(text: string): void {
  if (!wasm) return;
  const bytes = encoder.encode(text);
  const [ptr, cap] = write(bytes);
  if (wasm.tv_message(ptr, bytes.length, cap)) {
    dirty = true;
    lastNews = performance.now();
    loop();
  }
}

/** The page's font's advances for printable ASCII, and one for anything else, to Rust. */
function measure(): void {
  if (!wasm || !context || !start) return;
  context.font = start.font;
  const advances = new Float32Array(95);
  for (let at = 0; at < 95; at++) advances[at] = context.measureText(String.fromCharCode(32 + at)).width;
  const other = context.measureText("é").width || advances[33]!;
  const [ptr, cap] = write(new Uint8Array(advances.buffer));
  wasm.tv_advance(ptr, 95, cap, other);
}

function paint(): void {
  if (!wasm || !context || !start) return;
  const count = wasm.tv_layout();
  const text = decoder.decode(new Uint8Array(wasm.memory.buffer, wasm.tv_text_ptr(), wasm.tv_text_len()));
  const lines = new Float32Array(wasm.memory.buffer, wasm.tv_lines_ptr(), count * 2);
  const { width, height, dpr } = view;
  context.setTransform(dpr, 0, 0, dpr, 0, 0);
  context.fillStyle = start.colors.background;
  context.fillRect(0, 0, width, height);
  context.textBaseline = "bottom";
  context.font = start.font;
  let from = 0;
  for (let at = 0; at < count; at++) {
    const end = text.indexOf("\n", from);
    const line = end === -1 ? text.slice(from) : text.slice(from, end);
    from = end + 1;
    const style = lines[at * 2 + 1];
    context.fillStyle = style === USER || style === REPLY ? start.colors.text : start.colors.muted;
    context.fillText(line, 8, lines[at * 2]!);
  }
}

function note(gap: number): void {
  if (!start?.tally || !(gap > 0) || gap >= FLUSH_MS) return;
  const index = Math.min(BUCKETS, Math.floor(gap / BUCKET_MS + 1e-9));
  counts.set(index, (counts.get(index) ?? 0) + 1);
}

function flush(): void {
  if (counts.size === 0 || socket?.readyState !== WebSocket.OPEN) return;
  const gaps = [...counts.entries()].sort((a, b) => a[0] - b[0]);
  counts = new Map();
  socket.send(
    JSON.stringify({
      jsonrpc: "2.0",
      id: nextId++,
      method: "_acpmux/perf",
      params: { op: "tally", bucketMs: BUCKET_MS, gaps, painter: "native" },
    }),
  );
}

/** Draws on this Worker's frames while news comes, then rests (an idle chat asks for no frame). */
function loop(): void {
  if (looping) return;
  looping = true;
  lastFrame = 0;
  const frame = (at: number) => {
    if (lastFrame) note(at - lastFrame);
    lastFrame = at;
    if (dirty) {
      dirty = false;
      paint();
    }
    if (at - lastNews < BUSY_MS) scope.requestAnimationFrame(frame);
    else looping = false;
  };
  scope.requestAnimationFrame(frame);
}

function dial(command: Extract<NativeTranscriptCommand, { type: "start" }>): void {
  const ws = new WebSocket(command.endpoint, command.protocols);
  socket = ws;
  const send = (method: string, params: unknown) =>
    ws.send(JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }));
  ws.onopen = () => {
    send("initialize", { protocolVersion: 1, clientInfo: { name: "cmux-native-transcript" } });
    send("_acpmux/attach", { sessionId: command.sessionId });
  };
  ws.onmessage = (event) => {
    if (typeof event.data === "string") feed(event.data);
  };
  if (command.tally) setInterval(flush, FLUSH_MS);
}

scope.onmessage = async ({ data }) => {
  if (data.type === "view") {
    view = { width: data.width, height: data.height, dpr: data.dpr };
    if (start) {
      start.canvas.width = Math.max(1, Math.round(data.width * data.dpr));
      start.canvas.height = Math.max(1, Math.round(data.height * data.dpr));
    }
    wasm?.tv_view(data.width, data.height, start?.lineHeight ?? 16, 8, 8);
    dirty = true;
    lastNews = performance.now();
    loop();
    return;
  }
  start = data;
  context = data.canvas.getContext("2d");
  const module = await WebAssembly.instantiateStreaming(fetch(new URL("./transcript_view.wasm", import.meta.url)));
  wasm = module.instance.exports as unknown as Exports;
  measure();
  wasm.tv_view(view.width, view.height, data.lineHeight, 8, 8);
  if (view.width) {
    data.canvas.width = Math.max(1, Math.round(view.width * view.dpr));
    data.canvas.height = Math.max(1, Math.round(view.height * view.dpr));
  }
  dial(data);
};
