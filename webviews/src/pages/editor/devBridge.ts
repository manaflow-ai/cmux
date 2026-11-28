// Dev server only (/editor, dev-server/plugins.ts): a stand-in for the app's cmuxPage bridge, so the
// editor page runs unchanged in a plain browser. Calls go to POST /__cmux-editor/op, where the server
// implements the host ops (host.ts) on the `?file=` file. Two app roles are played here: the file
// watcher (`cmux.editor.changes`, from the server's hot-update event) and the key dispatcher, which
// turns the app's chords into page commands (Cmd-S `save`, Cmd-F `find` ...) and swallows the chords
// the app binds globally, so they never reach Monaco here either (keys.ts, README.md). Without
// `?file=` the page starts with no file (the empty state): `cmux.editor.chooseFile` shows the in-page
// fallback picker. Nothing here ships.
import { PAGE_COMMAND } from "../shared/pageStreams";
import { RECEIVE_NAME } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { devOp, showDevPicker } from "../../viewer-empty/dev";
import table from "./generated/strings.json";
import { EDITOR_CHANGES, EDITOR_CHOOSE_FILE_OP, EDITOR_LOOK, EDITOR_OPEN_OP, EDITOR_RECENTS_OP } from "./host";
import { DEV_DISPATCHER } from "./devKeys";
import { EMPTY } from "./strings";

type Envelope = {
  t: string;
  id?: number;
  op?: string;
  params?: unknown;
  stream?: string;
  sub?: number;
  value?: unknown;
};

// The file the page shows: the `?file=` it opened with, then each file it opens.
let file = new URLSearchParams(location.search).get("file") ?? "";
const streams = new Map<string, number>();
const seqs = new Map<number, number>();
const handlers = new Map<number, (value: unknown) => void>();
let nextSub = 1;
let nextCall = 1_000_000;

function receive(message: unknown): void {
  (globalThis as unknown as Record<string, (message: unknown) => void>)[RECEIVE_NAME]?.(message);
}

function emit(stream: string, data: unknown): void {
  const sub = streams.get(stream);
  if (sub === undefined) return;
  const seq = (seqs.get(sub) ?? 0) + 1;
  seqs.set(sub, seq);
  receive({ t: "ev", sub, seq, data });
}

async function op(name: string, params: unknown): Promise<{ ok: boolean; body: Record<string, unknown> }> {
  const response = await fetch("/__cmux-editor/op", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ file, op: name, params }),
  });
  return { ok: response.ok, body: (await response.json()) as Record<string, unknown> };
}

/** The host calling the page (`cmux.editor.flush`): resolves to the page's answer. */
export function callPage(name: string, params: unknown = {}): Promise<unknown> {
  const id = nextCall++;
  return new Promise((resolve) => {
    handlers.set(id, resolve);
    receive({ t: "call", id, op: name, params });
  });
}

async function postMessage(message: Envelope): Promise<unknown> {
  if (message.t === "ok" || message.t === "err") {
    const handler = handlers.get(message.id ?? -1);
    handlers.delete(message.id ?? -1);
    handler?.(message);
    return null;
  }
  if (message.t === "sub" && message.stream) {
    const sub = nextSub++;
    streams.set(message.stream, sub);
    return { t: "ok", id: message.id, value: { sub } };
  }
  if (message.t === "unsub") return null;
  if (message.t !== "call" || !message.op) return null;
  if (message.op === EDITOR_CHOOSE_FILE_OP) {
    const start = (message.params as { start?: unknown } | undefined)?.start;
    const strings = createStrings(table);
    return {
      t: "ok",
      id: message.id,
      value: await showDevPicker("anyFile", {
        start: typeof start === "string" ? start : null,
        labels: { title: strings.t(EMPTY.pickerTitle), empty: strings.t(EMPTY.pickerEmpty) },
      }),
    };
  }
  if (message.op === EDITOR_RECENTS_OP) {
    try {
      return { t: "ok", id: message.id, value: await devOp("/__cmux-viewer/op", EDITOR_RECENTS_OP, {}) };
    } catch (error) {
      return { t: "err", id: message.id, code: "cmux.page.failed", message: String(error) };
    }
  }
  const { ok, body } = await op(message.op, message.params ?? {});
  if (ok && message.op === "cmux.editor.config" && typeof body.path === "string") file = body.path;
  if (ok && message.op === EDITOR_OPEN_OP && typeof body.path === "string") {
    // The opened file is the page's file from now on, as the app's host keeps it.
    file = body.path;
    history.replaceState(null, "", `/editor?file=${encodeURIComponent(file)}`);
  }
  if (!ok)
    return { t: "err", id: message.id, code: body.code, message: body.message ?? body.code, details: body.details };
  if (message.op === "cmux.editor.openLink" && typeof body.url === "string") {
    window.open(body.url, "_blank", "noopener");
  }
  return { t: "ok", id: message.id, value: body };
}

(window as unknown as { webkit: unknown }).webkit = { messageHandlers: { cmuxPage: { postMessage } } };
(window as unknown as { __cmuxEditorDev: unknown }).__cmuxEditorDev = { callPage, emit };

// The app's key dispatcher: its chords become page commands or are swallowed, never Monaco's.
addEventListener(
  "keydown",
  (event: KeyboardEvent) => {
    const action = DEV_DISPATCHER(event);
    if (!action) return;
    event.preventDefault();
    event.stopPropagation();
    if (action.command) emit(PAGE_COMMAND, action);
  },
  true,
);

// The file watcher: the server reports a change of a watched file; the page gets its new text.
if (import.meta.hot) {
  import.meta.hot.on("cmux-editor:look", (look: unknown) => emit(EDITOR_LOOK, look));
  import.meta.hot.on("cmux-editor:content", async (changed: { file: string }) => {
    if (!file || changed.file !== file) return;
    const { body } = await op("cmux.editor.read", {});
    emit(EDITOR_CHANGES, body.deleted ? { path: file, hash: null, deleted: true } : { path: file, ...body });
  });
}
