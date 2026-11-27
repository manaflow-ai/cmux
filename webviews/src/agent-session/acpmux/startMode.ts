import { useEffect, useSyncExternalStore } from "react";

/// The permission mode acpmux would start a new chat on a harness in (`_acpmux/start_mode`,
/// hub/start_mode.rs, cx-wx93i): the mode id, and its name when acpmux knows it. acpmux alone
/// decides it (a preset, a profile that pins its mode, the settings); a mode picked in a chat holds
/// for that chat only. The pane only asks, and names no mode it has no answer for.
export type StartMode = { modeId: string; name?: string };

/// Asks the connected acpmux; undefined when it sets no mode, cannot know, or predates the method.
/// Rejects when it could not ask (the socket closed, the request failed): no answer to keep.
export type AskStartMode = (harness: string, cwd?: string) => Promise<StartMode | undefined>;

/// acpmux's last answers, per harness and folder, kept per viewer: a pending chat draws the last
/// answer on its first frame (cx-uq9xi), then the one it asks for replaces it. Never the mode a
/// chat ran: only what acpmux answered. `null`: acpmux answered that it sets none there. A folder
/// acpmux has not answered for yet borrows the harness's latest answer anywhere, so the access chip
/// still holds its place on the first frame, naming no mode; that folder's answer then replaces it.
const STORAGE_KEY = "cmux.acpmux.startModes.v1";

let ask: AskStartMode | undefined;
/// Bumped whenever an answer may have changed (acpmux's `_acpmux/start_mode_changed`, which it
/// also sends when the `agents.defaultPermissionMode` setting changes; a new client): every
/// pending chat asks again. Showing the pane again asks nothing.
let generation = 0;
/// Bumped whenever a kept answer changed: every pending chat draws it.
let version = 0;
/// The generation the last ask that answered (or is in flight) was sent in: a managed-access probe
/// (useFullAccessProbe) asks only when no other ask went out in this generation. An ask that fails
/// gives its generation back (review 42 of #23322).
let askedGeneration = -1;
/// Bumped when an ask other than a probe failed: a shown chat's probe asks once more. A probe's own
/// failure bumps nothing, so it never retries itself in a loop.
let failedAsks = 0;
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

/// What this viewer kept for a new chat on `harness` in `cwd`: acpmux's answer (`cachedStartMode`),
/// `null` when acpmux answered that it sets no mode there (or, borrowed, in the folder it answered
/// last), `undefined` when acpmux never answered for `harness` here.
function keptAnswer(harness: string, cwd?: string): KeptStartMode | null | undefined {
  const all = load();
  const key = keyOf(harness, cwd);
  if (key in all || Object.keys(all).some((other) => other.startsWith(`${harness}\u0000`)))
    return cachedStartMode(harness, cwd) ?? null;
  return undefined;
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

/// #23322: acpmux's last answer said full access is managed off (`"fullAccess": "managed"`: MDM or a
/// team policy forces `sessions.allowFullAccess` off, an upper bound the person can't override).
/// Pane-wide, read from every answer, a mode-less one too; an answer without the field (MDM unset,
/// MDM true, an older daemon) turns it off.
let fullAccessManaged = false;
/// The last ask's ticket: only the newest ask's answer counts. An answer to an older ask (two asks in
/// flight across a push) changes nothing, also when the newer ask failed: what was kept stays.
let fullAccessAsked = 0;
/// The newest ticket whose answer said anything about full access (`rememberFullAccess`): an ask
/// that returns without one (acpmux refused it) did not tell the pane whether full access is managed.
let fullAccessAnswered = 0;

/// A ticket for an `_acpmux/start_mode` ask about to be sent (direct.ts `startMode`).
export function fullAccessTicket(): number {
  fullAccessAsked += 1;
  return fullAccessAsked;
}

/// Keeps what an answer's `fullAccess` field says (direct.ts `startMode`), unless a newer ask was
/// sent since. No ticket (the gallery): the newest.
export function rememberFullAccess(field: unknown, ticket: number = fullAccessTicket()): void {
  if (ticket < fullAccessAsked) return;
  fullAccessAnswered = ticket;
  const next = field === "managed";
  if (next === fullAccessManaged) return;
  fullAccessManaged = next;
  notify();
}

/// Whether full access is managed off: the mode menu disables its full-access rows.
export function useFullAccessManaged(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => fullAccessManaged,
    () => fullAccessManaged,
  );
}

/// A shown chat whose menu has a full-access row learns whether full access is managed off: once
/// per generation (a connect, `_acpmux/start_mode_changed`, a pick), and only when no pending chat
/// asked in it, so a push costs acpmux one ask, not one per composer (#23322).
export function useFullAccessProbe(harness: string | undefined, cwd: string | undefined, enabled: boolean): void {
  const asked = useSyncExternalStore(
    subscribe,
    () => `${generation}:${failedAsks}`,
    () => `${generation}:${failedAsks}`,
  );
  useEffect(() => {
    if (!enabled || !harness) return;
    let live = true;
    // After this commit's other effects: a pending chat's ask in the same generation answers it.
    queueMicrotask(() => {
      if (live && ask && askedGeneration !== generation) void askStartMode(harness, cwd, { probe: true });
    });
    return () => {
      live = false;
    };
  }, [enabled, harness, cwd, asked]);
}

/** Test seam: forget the kept answers this module read or wrote. A test file that clears
 * localStorage must also call this, or the next file in the same bun process starts with them. */
export function resetStartModesForTests(): void {
  memory = undefined;
  fullAccessManaged = false;
  fullAccessAsked = 0;
  fullAccessAnswered = 0;
  askedGeneration = -1;
  failedAsks = 0;
  version += 1;
  notify();
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
  // What the previous connection's daemon said about full access is not this one's: forgotten,
  // and an answer still on its way from it (an older ticket) changes nothing.
  fullAccessAsked += 1;
  fullAccessManaged = false;
  startModeChanged();
}

/// Asks acpmux now and keeps its answer. Without a client: the kept answer.
export async function askStartMode(
  harness: string,
  cwd?: string,
  { probe = false }: { probe?: boolean } = {},
): Promise<StartMode | undefined> {
  const source = ask;
  if (!source) return exactStartMode(harness, cwd);
  const sent = generation;
  askedGeneration = sent;
  const before = fullAccessAsked;
  // An ask that told the pane nothing about full access (it failed, or acpmux refused it): a shown
  // chat's probe asks again, once (`failedAsks`), unless this was that probe (reviews 42 and 45).
  const unanswered = () => {
    if (askedGeneration === sent) askedGeneration = -1;
    if (!probe && source === ask) {
      failedAsks += 1;
      notify();
    }
  };
  let mode: StartMode | undefined;
  try {
    mode = await source(harness, cwd);
  } catch {
    // Not asked (the socket closed under it, the request failed): acpmux said nothing, so the
    // kept answer stays. Kept as "sets none", the chip lost its mode until the next answer.
    unanswered();
    return exactStartMode(harness, cwd);
  }
  // Answered, but with a refusal (an unavailable harness): the mode it sets is none, and whether
  // full access is managed is still unknown.
  if (fullAccessAnswered <= before) unanswered();
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
/// the first frame, asked again on mount and whenever it may have changed. `null`: acpmux sets no
/// mode there; `undefined`: no answer yet (or not `enabled`).
export function useStartMode(
  harness: string | undefined,
  cwd: string | undefined,
  enabled: boolean,
): KeptStartMode | null | undefined {
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
  // The kept answer lives outside React: `state` (bumped whenever it changes) is passed in, so the
  // React Compiler reads it again when an answer lands. Memoized on `harness` and `cwd` alone, an
  // answer that came after the first frame never reached the chip (cx-ncc.113.116: a cold New Tab
  // showed no mode control at all).
  return key && harness ? keptAt(state, harness, cwd) : undefined;
}

/// `keptAnswer`, read at store state `_state` (see useStartMode).
function keptAt(_state: string, harness: string, cwd?: string): KeptStartMode | null | undefined {
  return keptAnswer(harness, cwd);
}
