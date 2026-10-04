// Dev server only (/markdown, dev-server/plugins.ts): a stand-in for the app's cmuxPage bridge, so
// the markdown page runs unchanged in a plain browser. Calls go to POST /__cmux-markdown/op, where
// the server implements the host ops (host.ts) on the `?file=` file. Two app roles are played here:
// the file watcher (`cmux.markdown.changes`, from the server's hot-update event) and the key
// dispatcher, which turns Cmd-S into the `save` page command. Nothing here ships.
import { PAGE_COMMAND } from "../shared/pageStreams";
import { RECEIVE_NAME } from "../shared/pageClient";
import { MARKDOWN_CHANGES } from "./host";

type Envelope = { t: string; id?: number; op?: string; params?: unknown; stream?: string; sub?: number };

const file = new URLSearchParams(location.search).get("file") ?? "";
const streams = new Map<string, number>();
const seqs = new Map<number, number>();
let nextSub = 1;

function emit(stream: string, data: unknown): void {
  const sub = streams.get(stream);
  if (sub === undefined) return;
  const seq = (seqs.get(sub) ?? 0) + 1;
  seqs.set(sub, seq);
  const receive = (globalThis as unknown as Record<string, (message: unknown) => void>)[RECEIVE_NAME];
  receive?.({ t: "ev", sub, seq, data });
}

async function op(name: string, params: unknown): Promise<{ ok: boolean; body: Record<string, unknown> }> {
  const response = await fetch("/__cmux-markdown/op", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ file, op: name, params }),
  });
  return { ok: response.ok, body: (await response.json()) as Record<string, unknown> };
}

async function postMessage(message: Envelope): Promise<unknown> {
  if (message.t === "sub" && message.stream) {
    const sub = nextSub++;
    streams.set(message.stream, sub);
    return { t: "ok", id: message.id, value: { sub } };
  }
  if (message.t === "unsub") return null;
  if (message.t !== "call" || !message.op) return null;
  const { ok, body } = await op(message.op, message.params ?? {});
  if (!ok)
    return { t: "err", id: message.id, code: body.code, message: body.message ?? body.code, details: body.details };
  if (message.op === "cmux.markdown.openLink") {
    if (typeof body.navigate === "string") location.assign(body.navigate);
    else if (typeof body.url === "string") window.open(body.url, "_blank", "noopener");
  }
  return { t: "ok", id: message.id, value: body };
}

(window as unknown as { webkit: unknown }).webkit = { messageHandlers: { cmuxPage: { postMessage } } };

// The app's key dispatcher: Cmd-S saves through the page command, never a page key handler.
addEventListener(
  "keydown",
  (event: KeyboardEvent) => {
    if (event.metaKey && !event.shiftKey && !event.altKey && event.key.toLowerCase() === "s") {
      event.preventDefault();
      emit(PAGE_COMMAND, { command: "save" });
    }
  },
  true,
);

// The file watcher: the server reports a change of a watched file; the page gets its new text.
if (import.meta.hot) {
  import.meta.hot.on("cmux-markdown:content", async (changed: { file: string }) => {
    const { body } = await op("cmux.markdown.read", {});
    if (!file || !changed.file.endsWith(file.replace(/^.*\//, ""))) return;
    emit(
      MARKDOWN_CHANGES,
      body.deleted ? { path: changed.file, hash: null, deleted: true } : { path: changed.file, ...body },
    );
  });
}
