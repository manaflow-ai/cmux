import { useEffect, useSyncExternalStore } from "react";

/// The permission mode acpmux would start a new chat on a harness in (`_acpmux/start_mode`,
/// hub/start_mode.rs, cx-wx93i): the mode id, and its name when acpmux knows it. acpmux alone
/// decides it (the latest pick, a preset, a profile that pins its mode, the settings); the pane
/// only asks, and names no mode it has no answer for.
export type StartMode = { modeId: string; name?: string };

/// Asks the connected acpmux; undefined when it sets no mode, cannot know, or predates the method.
export type AskStartMode = (harness: string, cwd?: string) => Promise<StartMode | undefined>;

/// acpmux's last answers, per harness and folder, kept per viewer: a pending chat draws the last
/// answer on its first frame (cx-uq9xi), then the one it asks for replaces it. Never the mode a
/// chat ran: only what acpmux answered. `null`: acpmux answered that it sets none there. A folder
/// acpmux has not answered for yet borrows the harness's latest answer anywhere, so the access chip
/// still holds its place on the first frame, naming no mode; that folder's answer then replaces it.
const STORAGE_KEY = "cmux.acpmux.startModes.v1";

let ask: AskStartMode | undefined;
/// Bumped whenever an answer may have changed (acpmux's `_acpmux/start_mode_changed`, this
/// pane's own pick, the pane shown again, a new client): every pending chat asks again.
let generation = 0;
/// Bumped whenever a kept answer changed: every pending chat draws it.
let version = 0;
/// The kept answers, read from storage once per page (each pane asks acpmux itself; storage only
/// gives a new page its first frame).
let memory: Record<string, StartMode | null> | undefined;
const listeners = new Set<() => void>();
/// Told only when an answer may have changed (they ask again).
const askers = new Set<() => void>();

function notify(): void {
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

const keyOf = (harness: string, cwd?: string) => `${harness}\u0000${cwd ?? ""}`;

function load(): Record<string, StartMode | null> {
  if (!memory) {
    memory = {};
    try {
      const value: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}");
      if (value && typeof value === "object") memory = { ...(value as Record<string, StartMode | null>) };
    } catch {
      // Unreadable: no kept answers.
    }
  }
  return memory;
}

function save(all: Record<string, StartMode | null>): void {
  memory = all;
  version += 1;
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(all));
  } catch {
    // Storage unavailable: this page keeps them.
  }
  notify();
}

function valid(mode: unknown): mode is StartMode {
  const value = mode as StartMode | undefined;
  return (
    !!value &&
    typeof value.modeId === "string" &&
    !!value.modeId &&
    (value.name === undefined || typeof value.name === "string")
  );
}

/// A kept answer; `borrowed`: acpmux has not answered for this folder yet, and this is its latest
/// answer for the harness in another folder. A borrowed answer only holds the chip's place: that
/// folder's profile or preset may start the chat in another mode, so it names no mode.
export type KeptStartMode = StartMode & { borrowed?: true };

/// acpmux's last answer for a new chat on `harness` in `cwd`, as this viewer saw it; for a folder
/// it has not answered yet, its latest answer for `harness` in any folder, marked `borrowed`.
export function cachedStartMode(harness: string | undefined, cwd?: string): KeptStartMode | undefined {
  if (!harness) return undefined;
  const all = load();
  const key = keyOf(harness, cwd);
  if (key in all) {
    const mode = all[key];
    return valid(mode) ? mode : undefined;
  }
  // Answers are kept latest last (`rememberStartMode`).
  const latest = Object.keys(all)
    .filter((other) => other.startsWith(`${harness}\u0000`))
    .at(-1);
  const mode = latest === undefined ? undefined : all[latest];
  return valid(mode) ? { ...mode, borrowed: true } : undefined;
}

/// acpmux's last answer for `harness` in this very folder; none borrowed from another.
export function exactStartMode(harness: string | undefined, cwd?: string): StartMode | undefined {
  const mode = cachedStartMode(harness, cwd);
  return mode?.borrowed ? undefined : mode;
}

/// Keeps `mode` as acpmux's answer for `harness` in `cwd` (none: acpmux sets none there).
export function rememberStartMode(harness: string, cwd: string | undefined, mode: StartMode | undefined): void {
  const all = { ...load() };
  const key = keyOf(harness, cwd);
  const before = all[key];
  const same = mode
    ? valid(before) && before.modeId === mode.modeId && before.name === mode.name
    : key in all && before === null;
  const ofHarness = (other: string) => other.startsWith(`${harness}\u0000`);
  if (same && Object.keys(all).filter(ofHarness).at(-1) === key) return;
  // Latest last: a folder with no answer of its own draws this one.
  delete all[key];
  all[key] = mode ?? null;
  save(all);
}

/// This pane picked `mode` (named `name`) in a local chat on `harness`, and acpmux took it: its
/// kept answers for that harness say so at once, then every pending chat asks acpmux again, which
/// corrects any that acpmux did not take as a pick (a preset's chat, a profile that pins it).
export function pickedMode(harness: string | undefined, mode: string, name?: string): void {
  if (harness && mode) {
    const all = { ...load() };
    const keys = Object.keys(all).filter((key) => key.startsWith(`${harness}\u0000`));
    for (const key of keys) all[key] = { modeId: mode, ...(name ? { name } : {}) };
    if (keys.length > 0) save(all);
  }
  startModeChanged();
}

/// acpmux's answer may have changed: every pending chat asks again.
export function startModeChanged(): void {
  generation += 1;
  for (const asker of askers) asker();
  notify();
}

/// The pane's connected client answers (direct.ts `startMode`); none while disconnected. A chip
/// drawn before the client connected asks once it does.
export function setStartModeSource(next: AskStartMode | undefined): void {
  if (ask === next) return;
  ask = next;
  if (next) watchPage();
  startModeChanged();
}

let watchingPage = false;
/// The pane shown or focused again (Settings may have changed the default meanwhile, which acpmux
/// does not announce): pending chats ask again. Also covers daemons that send no notice.
function watchPage(): void {
  if (watchingPage || typeof document === "undefined") return;
  watchingPage = true;
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") startModeChanged();
  });
  globalThis.addEventListener?.("focus", () => startModeChanged());
}

/// Asks acpmux now and keeps its answer. Without a client: the kept answer.
export async function askStartMode(harness: string, cwd?: string): Promise<StartMode | undefined> {
  const source = ask;
  if (!source) return exactStartMode(harness, cwd);
  const mode = await source(harness, cwd).catch(() => undefined);
  rememberStartMode(harness, cwd, mode);
  return mode;
}

/// Calls `listener` whenever a kept answer changed (or may have).
export const onStartModeKept = subscribe;

/// Calls `asker` whenever acpmux's answer may have changed: a pending chat asks again.
export function onStartModeAskAgain(asker: () => void): () => void {
  askers.add(asker);
  return () => void askers.delete(asker);
}

/// The mode a new chat on `harness` in `cwd` starts in, while `enabled`: acpmux's kept answer from
/// the first frame, asked again on mount and whenever it may have changed.
export function useStartMode(harness: string | undefined, cwd: string | undefined, enabled: boolean) {
  const state = useSyncExternalStore(
    subscribe,
    () => `${generation}:${version}`,
    () => `${generation}:${version}`,
  );
  const asked = state.split(":")[0];
  const key = enabled && harness ? keyOf(harness, cwd) : undefined;
  useEffect(() => {
    if (key && harness) void askStartMode(harness, cwd);
  }, [key, harness, cwd, asked]);
  return key ? cachedStartMode(harness, cwd) : undefined;
}
