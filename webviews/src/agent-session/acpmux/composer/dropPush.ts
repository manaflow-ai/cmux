// Where the files of the person's native drop are, pushed by the host with the drop itself (Leo,
// 2026-11-18: "you can just send it instantly. Like, stop blocking."). The pane's host dispatches
// `cmux-files-dropped` on the window as it takes the native drop: WebKit gets it before the page's
// DOM drop (the host queues it in `performDragOperation`, ahead of the drop it hands WebKit),
// Chromium right after the page's own drop message. The page uses it with no request:
// - a chat on this Mac links each file where it is (`pushedDropPaths`), and asks the host
//   (`chat.attach.dropped`) only when no push comes, as an older host needs;
// - a chat on another machine has the host put each file there straight from its path
//   (`uploadDropped`: `chat.upload.begin` naming the push's token), so no byte of it crosses the
//   page bridge; a paste, or a drop with no path, still uploads through the bridge.
import type { KnownPaths, LinkItem } from "../attachments";
import type { UploadCancelled, UploadProgressReport, UploadResult } from "../cloudUploads";
import { translate } from "../i18n";

/// The window event the host dispatches with a native drop's files (AgentPaneView+ContextMenu.swift).
export const DROP_PUSH_EVENT = "cmux-files-dropped";
/// How long a pushed drop is kept for the page to take: as the host keeps its own record.
const LIFETIME_MS = 5_000;
/// How long after a DOM drop the page waits for its push before it goes on without it (Chromium's
/// push follows the page's drop message by one round trip; an older host never pushes).
export const PUSH_WAIT_MS = 250;

/// One dropped file or folder: its path on this Mac, and for a chat on another machine the host's
/// token for putting it there.
export type PushedItem = { path: string; folder: boolean; token?: string };
/// The host's push: `local` when the chat runs on this Mac (its files link where they are).
export type PushedDrop = { local: boolean; items: PushedItem[] };

type Held = { at: number; local: boolean; items: (PushedItem & { taken?: boolean })[] };
let held: Held[] = [];
let lastDrop: { at: number; names: Set<string> } | undefined;
/// When the last push came: one after the last DOM drop is that drop's (it is not waited for again).
let lastPushAt = -Infinity;
const waiting = new Set<() => void>();

const fresh = () => {
  const now = performance.now();
  held = held.filter((drop) => now - drop.at <= LIFETIME_MS && drop.items.some((item) => !item.taken));
};

/// Takes the host's push (the window event's detail).
export function receivePushedDrop(detail: unknown): void {
  const drop = (detail ?? {}) as { local?: unknown; items?: unknown };
  if (!Array.isArray(drop.items)) return;
  const items = drop.items.flatMap((entry: unknown) => {
    const { path, folder, token } = (entry ?? {}) as { path?: unknown; folder?: unknown; token?: unknown };
    if (typeof path !== "string" || !path.startsWith("/")) return [];
    return [{ path, folder: folder === true, ...(typeof token === "string" && token ? { token } : {}) }];
  });
  if (!items.length) return;
  fresh();
  lastPushAt = performance.now();
  held.push({ at: lastPushAt, local: drop.local === true, items });
  for (const wake of waiting) wake();
}

/// The page took a DOM drop of `files`: their push, if it has not come yet, is waited for.
export function noteDomDrop(files: readonly File[]): void {
  lastDrop = { at: performance.now(), names: new Set(files.map((file) => file.name.normalize("NFC"))) };
}

/// Forgets every push (tests).
export function clearPushedDrops(): void {
  held = [];
  lastDrop = undefined;
  lastPushAt = -Infinity;
}

/// Listens on `target` (the page's window) for the host's push and the page's DOM drops.
export function listenForDropPush(target: EventTarget): void {
  target.addEventListener(DROP_PUSH_EVENT, (event) => receivePushedDrop((event as CustomEvent).detail));
  // Capture: before the composer's own drop handler reads the files.
  target.addEventListener(
    "drop",
    (event) => {
      const files = (event as DragEvent).dataTransfer?.files;
      if (files?.length) noteDomDrop(Array.from(files));
    },
    true,
  );
}

if (typeof window !== "undefined" && typeof window.addEventListener === "function") listenForDropPush(window);

const basename = (path: string) => path.replace(/\/+$/, "").split("/").pop() ?? "";
/// Whether WebKit names the file at `path` `name`: its own name, or `<name>.zip` for a folder.
const named = (path: string, name: string) => {
  const last = basename(path).normalize("NFC");
  const asked = name.normalize("NFC");
  return asked === last || asked === `${last}.zip`;
};

/// The newest local push that holds exactly `files`, in their order, used up; undefined otherwise.
function takeLocal(files: readonly File[]): LinkItem[] | undefined {
  fresh();
  for (const drop of [...held].reverse()) {
    if (!drop.local || drop.items.length !== files.length || drop.items.some((item) => item.taken)) continue;
    const left = [...drop.items];
    const picked: PushedItem[] = [];
    for (const file of files) {
      const at = left.findIndex((item) => named(item.path, file.name));
      if (at < 0) break;
      picked.push(left.splice(at, 1)[0]!);
    }
    if (picked.length !== files.length) continue;
    for (const item of drop.items) item.taken = true;
    // A folder: the host says so, or WebKit named it `<name>.zip`.
    return picked.map((item, index) => ({
      path: item.path,
      folder: item.folder || basename(item.path).normalize("NFC") !== files[index]!.name.normalize("NFC"),
    }));
  }
  return undefined;
}

/// Whether a push for a chat on another machine holds every file of `files`, untaken.
function heldRemote(files: readonly File[]): boolean {
  fresh();
  return held.some(
    (drop) =>
      !drop.local && files.every((file) => drop.items.some((item) => !item.taken && named(item.path, file.name))),
  );
}

/// The newest remote push's untaken item for a file named `name`, used up.
function takeRemote(name: string): PushedItem | undefined {
  fresh();
  for (const drop of [...held].reverse()) {
    if (drop.local) continue;
    const item = drop.items.find((entry) => !entry.taken && entry.token && named(entry.path, name));
    if (item) {
      item.taken = true;
      return item;
    }
  }
  return undefined;
}

/// Resolves when a push comes, or after `ms`; `stop` ends the wait early.
function nextPush(ms: number): Promise<void> {
  return new Promise((resolve) => {
    const wake = () => {
      waiting.delete(wake);
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(wake, ms);
    waiting.add(wake);
  });
}

/// Where the files of the person's drop on a chat on this Mac are: from the host's push when it has
/// come (no request), else the first of the push and `ask` (`chat.attach.dropped`, an older host) to
/// know them. Undefined when neither does.
export function pushedDropPaths(
  files: readonly File[],
  ask: () => Promise<KnownPaths | undefined>,
): Promise<KnownPaths | undefined> {
  const now = takeLocal(files);
  if (now) return Promise.resolve(now);
  // The host pushed these files for a chat on another machine: nothing links, and nothing waits.
  if (heldRemote(files)) return Promise.resolve(undefined);
  return new Promise((resolve) => {
    let done = false;
    let asked = false;
    let waited = false;
    const finish = (items: KnownPaths | undefined) => {
      if (done) return;
      done = true;
      waiting.delete(wake);
      clearTimeout(timer);
      resolve(items);
    };
    const wake = () => {
      const items = takeLocal(files);
      if (items) finish(items);
      else if (heldRemote(files)) finish(undefined);
    };
    waiting.add(wake);
    const timer = setTimeout(() => {
      waited = true;
      if (asked) finish(undefined);
    }, PUSH_WAIT_MS);
    void ask().then(
      (items) => {
        asked = true;
        if (items) finish(items);
        // Past the wait, or the drop's push already came and named other files: none come.
        else if (waited || (lastDrop && lastPushAt >= lastDrop.at)) finish(undefined);
      },
      () => {
        asked = true;
        if (waited) finish(undefined);
      },
    );
  });
}

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
type Upload = (files: File[], cancelled?: UploadCancelled, progress?: UploadProgressReport) => Promise<UploadResult>;
/// Codes of a host that cannot put a file from its path: the file goes through the bridge instead.
const NOT_TAKEN = new Set(["unsupported", "native.invalid_request"]);

type Put = { path: string } | { error: string; final?: boolean } | "bridge";

/// Puts the dropped file `file` on the chat's machine from its path on this Mac (the host streams
/// it, off the page). The tile's x cancels it by its token.
async function put(
  call: Call,
  file: File,
  token: string,
  index: number,
  cancelled: UploadCancelled,
  progress?: UploadProgressReport,
): Promise<Put> {
  if (cancelled(index)) return { path: "" };
  const stop = cancelled.subscribe?.(index, () => {
    if (cancelled(index)) void call("chat.upload.cancel", { token }).catch(() => undefined);
  });
  try {
    const reply = (await call("chat.upload.begin", { name: file.name, size: file.size, batchToken: token })) as {
      path?: unknown;
      uploads?: { path?: unknown }[];
    } | null;
    if (cancelled(index)) return { path: "" };
    // As a staged upload's finish answers: `{path}` (a peer), or `{uploads: [{name, path}]}` (Cloud).
    const found = reply?.path ?? (Array.isArray(reply?.uploads) ? reply.uploads[0]?.path : undefined);
    const path = typeof found === "string" && found.startsWith("/") ? found : undefined;
    if (!path) return { error: translate("upload.notCompleted") };
    progress?.(index, 1);
    return { path };
  } catch (error) {
    if (cancelled(index)) return { path: "" };
    const code = (error as { code?: string } | null)?.code ?? "";
    if (NOT_TAKEN.has(code)) return "bridge";
    return { error: error instanceof Error ? error.message : String(error), ...(code === "io" ? { final: true } : {}) };
  } finally {
    stop?.();
  }
}

/// The chat's upload of `files` (a chat on another machine): each file of the person's drop whose
/// path the host pushed goes from that path (`put`); the rest, and any the host cannot put, through
/// `bridge` (cloudUploads.ts `uploadToMachine`), as before.
export async function uploadDropped(
  files: File[],
  call: Call,
  bridge: Upload,
  cancelled: UploadCancelled = () => false,
  progress?: UploadProgressReport,
): Promise<UploadResult> {
  const tokens: (string | undefined)[] = files.map((file) => takeRemote(file.name)?.token);
  // A file of the drop the page just took whose push has not come yet (Chromium): wait for it.
  const recent =
    lastDrop && performance.now() - lastDrop.at <= LIFETIME_MS && lastPushAt < lastDrop.at ? lastDrop.names : undefined;
  const late = () => files.some((file, at) => !tokens[at] && recent?.has(file.name.normalize("NFC")));
  if (late()) {
    const until = performance.now() + PUSH_WAIT_MS;
    while (late() && performance.now() < until) {
      await nextPush(until - performance.now());
      files.forEach((file, at) => {
        if (!tokens[at] && recent?.has(file.name.normalize("NFC"))) tokens[at] = takeRemote(file.name)?.token;
      });
    }
  }
  if (tokens.every((token) => !token)) return bridge(files, cancelled, progress);
  const through = async (indices: number[]): Promise<UploadResult> => {
    if (!indices.length) return { paths: [] };
    const subset = Object.assign((at: number) => cancelled(indices[at]!), {
      subscribe: (at: number, changed: () => void) => cancelled.subscribe?.(indices[at]!, changed) ?? (() => {}),
    });
    return bridge(
      indices.map((index) => files[index]!),
      subset,
      progress ? (at, done) => progress(indices[at]!, done) : undefined,
    );
  };
  const paths: string[] = files.map(() => "");
  let failure: { error: string; final?: boolean } | undefined;
  const take = (indices: number[], sent: UploadResult) => {
    if (sent && "paths" in sent) indices.forEach((index, at) => (paths[index] = sent.paths[at] ?? ""));
    if (sent && "error" in sent) failure ??= { error: sent.error, ...(sent.final ? { final: true } : {}) };
  };
  const unknown = files.flatMap((_, index) => (tokens[index] ? [] : [index]));
  const [puts, rest] = await Promise.all([
    Promise.all(
      files.map((file, index) =>
        tokens[index] ? put(call, file, tokens[index]!, index, cancelled, progress) : undefined,
      ),
    ),
    through(unknown),
  ]);
  take(unknown, rest);
  const again: number[] = [];
  puts.forEach((made, index) => {
    if (made === undefined) return;
    if (made === "bridge") again.push(index);
    else if ("path" in made) paths[index] = made.path;
    else failure ??= made;
  });
  if (again.length) take(again, await through(again));
  return failure ? { paths, ...failure } : { paths };
}
