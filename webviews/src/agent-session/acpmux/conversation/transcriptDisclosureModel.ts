import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import { type TranscriptView } from "./transcriptView";
import { forgetThoughtChoices } from "./thoughtChoices";

/**
 * Disclosure state for transcript details. Rows are virtualized, so the state cannot live in a
 * component's local `useState`: a command that scrolls out of the viewport would forget whether
 * the reader opened it. The key is the acpmux session plus a stable tool or group id.
 */
const STORAGE_KEY = "cmux.acpmux.transcriptDisclosure";
const SESSION_LIMIT = 40;
const DISCLOSURE_LIMIT = 600;
export const DEFAULT_SESSION = "__transcript__";
/// The prefix of a call's own key (`callDisclosureKey`).
const CALL_PREFIX = "row:";

type SessionChoices = Map<string, boolean>;
type Choices = Map<string, SessionChoices>;

let choices: Choices | undefined;
const listeners = new Set<() => void>();

function parseChoices(value: unknown): Choices {
  const result: Choices = new Map();
  if (!value || typeof value !== "object") return result;
  for (const [sessionId, rawSession] of Object.entries(value as Record<string, unknown>)) {
    if (!rawSession || typeof rawSession !== "object") continue;
    const session = new Map<string, boolean>();
    for (const [key, rawValue] of Object.entries(rawSession as Record<string, unknown>)) {
      if (typeof rawValue === "boolean") session.set(key, rawValue);
    }
    if (session.size) result.set(sessionId, session);
  }
  return result;
}

function load(): Choices {
  if (choices) return choices;
  try {
    choices = parseChoices(JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "null"));
  } catch {
    // Private windows, test DOMs and full storage fall back to the in-memory map.
    choices = new Map();
  }
  return choices;
}

function storageValue(): Record<string, Record<string, boolean>> {
  return Object.fromEntries([...load()].map(([sessionId, session]) => [sessionId, Object.fromEntries(session)]));
}

function notify(): void {
  for (const listener of listeners) listener();
}

function save(sessionId: string, key: string, value: boolean): void {
  const all = load();
  let session = all.get(sessionId);
  if (!session) all.set(sessionId, (session = new Map()));
  session.delete(key);
  session.set(key, value);
  while (session.size > DISCLOSURE_LIMIT) session.delete(session.keys().next().value!);
  while (all.size > SESSION_LIMIT) all.delete(all.keys().next().value!);
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(storageValue()));
  } catch {
    // The in-memory choice still lasts for this page when storage is unavailable.
  }
  notify();
}

/// Whether disclosure key `key` names one of `ids`: a call's (`row:<id>`), a group's or run's line
/// (`group:<kind>:<id>`, `run:<id>`, with `<row id>:<n>` when no call names it), a thought
/// (`<row id>:thought:<n>`). Every stretch between two colons, or from one to the end, is tried.
function namesOne(key: string, ids: ReadonlySet<string>): boolean {
  const marks = [-1];
  for (let at = key.indexOf(":"); at >= 0; at = key.indexOf(":", at + 1)) marks.push(at);
  for (let from = 0; from < marks.length; from += 1) {
    if (ids.has(key.slice(marks[from]! + 1))) return true;
    for (let to = from + 1; to < marks.length; to += 1)
      if (ids.has(key.slice(marks[from]! + 1, marks[to]))) return true;
  }
  return false;
}

/// How deep a line nests: a call or thought (0) in a group (1) in a run (2). A run's or group's key
/// names its first call, as the calls in it do, so a fold forgets only lines below its own level and
/// never the run around it (`run:e1` over `group:edits:e1`).
function level(key: string): number {
  if (key.startsWith(CALL_PREFIX) || key.includes(":thought:")) return 0;
  return key.startsWith("run:") ? 2 : 1;
}

/// Forget the reader's choices on every line inside a fold they closed, so the fold opens again with
/// each of them closed (Lucas, 2026-11-11: "if a tool call gets expanded, and its parent gets
/// collapsed, when the parent expands again, all children should go back to being collapsed").
/// `ids`: the calls and rows the fold holds (`namesOne`). `below`: the fold's own level (`level`);
/// only lines under it are forgotten. `keep`: lines that take the fold's place, never its children.
/// `views`: the chat's other views (`chat#view`) too. `from`: the lowest level forgotten.
/// A forgotten line goes back to its default, as on the parent's first open: closed, or open where
/// the turn's look opens it (a steered turn's runs under `nested-open`).
function forgetInside(
  sessionId: string,
  ids: ReadonlySet<string>,
  below: number,
  keep: ReadonlySet<string> = new Set(),
  views = false,
  from = 0,
): void {
  if (ids.size === 0) return;
  let changed = false;
  for (const [id, session] of load()) {
    if (id !== sessionId && !(views && id.startsWith(`${sessionId}#`))) continue;
    for (const [key, value] of session) {
      if (!value || keep.has(key) || level(key) >= below || level(key) < from || !namesOne(key, ids)) continue;
      session.delete(key);
      changed = true;
    }
  }
  if (!changed) return;
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(storageValue()));
  } catch {
    // The in-memory change still lasts for this page when storage is unavailable.
  }
  notify();
}

/// A turn's "Worked for" closed (App.tsx): every line inside it closes, in every view of the chat,
/// its thoughts too (`<row id>:thought:<n>`, thoughtChoices.ts). `edits`: the turn's edit calls,
/// whose own lines (`row:<id>`) the edited-files card under the answer shares: only the runs and
/// groups they start are forgotten (`run:<edit id>`).
export function forgetInsideTurn(
  sessionId: string | undefined,
  ids: ReadonlySet<string>,
  edits?: ReadonlySet<string>,
): void {
  forgetInside(sessionId || DEFAULT_SESSION, ids, Infinity, undefined, true);
  if (edits?.size) forgetInside(sessionId || DEFAULT_SESSION, edits, Infinity, undefined, true, 1);
  if (ids.size > 0) forgetThoughtChoices((id) => namesOne(id, ids));
}

function read(sessionId: string, key: string): boolean | undefined {
  return load().get(sessionId)?.get(key);
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

export const DisclosureSession = createContext<string>(DEFAULT_SESSION);
/** The chat's transcript view (transcriptView.ts), read once here for every row under it. */
export const ViewContext = createContext<TranscriptView>("normal");

/// The chat a transcript's disclosure id belongs to, whose view the chat menu sets: a subagent's
/// transcript (`<chat>:subagent:<id>`) and a replay (`replay:<chat>`) follow their chat's view.
export function viewChat(sessionId: string | undefined): string | undefined {
  if (!sessionId) return undefined;
  const chat = sessionId.startsWith("replay:") ? sessionId.slice("replay:".length) : sessionId;
  const subagent = chat.indexOf(":subagent:");
  return subagent < 0 ? chat : chat.slice(0, subagent);
}

/** The chat's transcript view: Normal, Thinking (thoughts open) or Verbose (tool output open too). */
export const useTranscriptViewContext = (): TranscriptView => useContext(ViewContext);

export type DisclosureSetter = (value: boolean | ((current: boolean) => boolean)) => void;

const NONE: readonly string[] = [];

/// The value a disclosure reads before the reader set its own: its default, or open when the reader
/// opened any of the keys it `inherits` (a fold that took the place of those, as a run's line takes
/// the place of the group it grew from). Keys are joined with "\n" so the memo compares a string.
function inherited(sessionId: string, inherits: string): boolean {
  return inherits !== "" && inherits.split("\n").some((key) => read(sessionId, key) === true);
}

/// Whether the reader closed every line in `closedBy` (joined with "\n"), each after they last set
/// `key`: then `key` reads closed whatever it held or would open to. A choice on `key` made after them
/// is the newer one and stands. The store keeps each session's choices in the order they were made
/// (`save` moves a key to the end), so the order of its keys is the order of the reader's choices.
function closedOver(sessionId: string, key: string, closedBy: string): boolean {
  if (closedBy === "") return false;
  const lines = closedBy.split("\n");
  if (!lines.every((line) => read(sessionId, line) === false)) return false;
  const session = load().get(sessionId);
  if (session?.get(key) === undefined) return true;
  const pending = new Set(lines);
  let after = false;
  for (const stored of session.keys()) {
    if (stored === key) after = true;
    else if (pending.has(stored) && !after) return false;
  }
  return true;
}

/// Whether the reader opened a line in `inherits` (joined with "\n") after they last set `key`, or
/// opened one and never set `key`: then `key` reads open, over `closedOver` too. A line the reader
/// opened stays open when another takes its place: an MCP group they opened in a run whose other
/// groups they closed one by one keeps the run's line open at the turn's end. An earlier opening loses
/// to a later choice on `key`, as `closedOver` orders them.
function openedOver(sessionId: string, key: string, inherits: string): boolean {
  if (inherits === "") return false;
  const opened = new Set(inherits.split("\n").filter((line) => read(sessionId, line) === true));
  if (opened.size === 0) return false;
  const session = load().get(sessionId)!;
  if (session.get(key) === undefined) return true;
  let after = false;
  for (const stored of session.keys()) {
    if (stored === key) after = true;
    else if (after && opened.has(stored)) return true;
  }
  return false;
}

/// How a disclosure follows the lines it takes the place of, or that take its place, as calls arrive
/// and a turn ends (TurnRows.tsx): a run's line and the group lines it grows from or splits into.
export type DisclosureLinks = {
  /// Keys of the lines this one replaced: one the reader opened opens this one until they set it, and
  /// one they opened after setting it opens it again (`openedOver`).
  inherits?: readonly string[];
  /// Keys this line hands the reader's choice to, those of them the reader had set: a run's line to
  /// the group lines it splits back into, so a line they closed never reopens as one of those.
  passesDown?: readonly string[];
  /// The calls a fold holds (`callDisclosureKey`). One the reader opened keeps the fold open until
  /// the reader sets the fold itself, as `inherits` does. Closing the fold forgets the reader's choice
  /// on each of them, so it opens again with every call closed (`forgetInside`).
  members?: readonly string[];
  /// Lines that close this one once the reader closed every one of them, after any choice they made
  /// on this one (`closedOver`): a run's line whose groups they closed one by one while the turn ran,
  /// or a group line whose run's line they closed.
  closedBy?: readonly string[];
  /// The ids of the thoughts the fold draws (thoughtChoices.ts): closing it forgets their open choices.
  thoughts?: readonly string[];
};

const NO_LINKS: DisclosureLinks = {};

/**
 * Returns a persisted disclosure value and a React-compatible setter. `verboseOpen` opens it by
 * default in the Verbose view (a tool's output). The reader's toggles are kept per view, so each
 * view starts from its own defaults and switching back finds the old toggles where they were.
 * `links`: the lines this one takes the place of or that take its place (`DisclosureLinks`), so a
 * line the reader opened stays open and one they closed stays closed (Leo, 2026-11-07: "I opened up,
 * expanded the tool calls, and then it closed on by itself").
 */
export function useTranscriptDisclosure(
  key: string,
  defaultOpen = false,
  verboseOpen = false,
  links: DisclosureLinks = NO_LINKS,
): [boolean, DisclosureSetter] {
  const view = useContext(ViewContext);
  const sessionId = useDisclosureSessionId();
  const opens = defaultOpen || (verboseOpen && view === "verbose");
  const from = (links.inherits ?? NONE).join("\n");
  const down = (links.passesDown ?? NONE).join("\n");
  const held = (links.members ?? NONE).join("\n");
  const by = (links.closedBy ?? NONE).join("\n");
  const thoughts = (links.thoughts ?? NONE).join("\n");
  const current = useCallback(
    () =>
      openedOver(sessionId, key, from) ||
      (!closedOver(sessionId, key, by) &&
        (read(sessionId, key) ?? (opens || inherited(sessionId, from) || inherited(sessionId, held)))),
    [sessionId, key, opens, from, held, by],
  );
  const open = useSyncExternalStore(subscribe, current, () => opens);
  const setOpen = useCallback<DisclosureSetter>(
    (value) => {
      const next = typeof value === "function" ? value(current()) : value;
      // Closed, the fold forgets what the reader opened inside it: its calls and the lines among them
      // (an edits group in a run), never itself, the run around it or the lines that take its place.
      if (!next && thoughts !== "") {
        const inside = new Set(thoughts.split("\n"));
        forgetThoughtChoices((id) => inside.has(id));
      }
      if (!next && held !== "")
        forgetInside(
          sessionId,
          new Set(held.split("\n").map((member) => member.slice(CALL_PREFIX.length))),
          level(key),
          // The group lines this one splits back into are its other form, never its children; an
          // edits group drawn inside a run is a child (it is not in `passesDown`), so it is forgotten.
          new Set([key, ...(down ? down.split("\n") : []), ...(by ? by.split("\n") : [])]),
        );
      // A run's line the reader set takes the place of the group lines it hands down to: one they had
      // set takes the same choice, so a run line they closed never reopens as its group's line when the
      // run splits back into groups. A line they never set keeps its own default, and a group's line
      // passes nothing up, so closing one group never closes its sibling through the run's key.
      if (down !== "")
        for (const other of down.split("\n")) if (read(sessionId, other) !== undefined) save(sessionId, other, next);
      save(sessionId, key, next);
    },
    [sessionId, key, current, down, held, by, thoughts],
  );
  return [open, setOpen];
}

/// The session a disclosure's choices are kept under: the chat's, and per view outside Normal.
function useDisclosureSessionId(): string {
  const view = useContext(ViewContext);
  const chat = useContext(DisclosureSession);
  return view === "normal" ? chat : `${chat}#${view}`;
}

/// The key of a tool call's own line (a lone call, a command, an MCP call), the same wherever the call
/// draws: on its own, in a group, in a run (TurnRows.tsx). A fold that holds the call opens for it.
export const callDisclosureKey = (id: string) => `${CALL_PREFIX}${id}`;

/// The keys of the calls among `items` (`callDisclosureKey`), for the fold that holds them (`members`).
export function callDisclosureKeys(items: readonly { tool?: { id: string } }[]): string[] {
  const keys: string[] = [];
  for (const item of items) if (item.tool?.id) keys.push(callDisclosureKey(item.tool.id));
  return keys;
}

/// The folds around a line (a group's, then its run's): `pin` keeps each where it is drawn now, so a
/// choice the reader makes inside a fold makes the fold theirs too, and it no longer folds on its own
/// when its run finishes or the run regroups (Leo, 2026-11-08: "if i have a tool call expanded, the
/// auto folding situation shouldn't collapse it when a new tool call comes in and the folds
/// reformat"). Outside any fold it does nothing.
export const FoldPin = createContext<() => void>(() => {});

/// The pin a fold under `key` gives the lines inside it: its own fold first (open, as the reader sees
/// it, unless the reader already set it), then the folds around it. Keyed reads only.
export function useFoldPin(key: string): () => void {
  const sessionId = useDisclosureSessionId();
  const outer = useContext(FoldPin);
  return useCallback(() => {
    outer();
    if (key !== "" && read(sessionId, key) === undefined) save(sessionId, key, true);
  }, [outer, sessionId, key]);
}

/**
 * A call's own details: closed, or open in the Verbose view. The reader's choice is kept per view in
 * the session's disclosures under the call's id (`callDisclosureKey`), so it outlasts the row: a new
 * call that groups it with this one ("Ran 2 commands"), a group that becomes a run, and the run's
 * fold all draw it anew, and it is open or closed as the reader left it. Setting it pins the folds
 * around it (`FoldPin`).
 */
export function useRowDisclosure(key: string | undefined): [boolean, (open: boolean) => void] {
  const pin = useContext(FoldPin);
  const [open, setKept] = useTranscriptDisclosure(key ? callDisclosureKey(key) : "", false, true);
  const setOpen = useCallback(
    (next: boolean) => {
      pin();
      setKept(next);
    },
    [pin, setKept],
  );
  return [open, setOpen];
}

/** Test/gallery reset; production callers keep each session's choices. */
export function resetTranscriptDisclosure(sessionId?: string): void {
  if (sessionId) {
    // With the views' own toggles (`session#view`).
    for (const id of load().keys()) if (id === sessionId || id.startsWith(`${sessionId}#`)) load().delete(id);
  } else choices = new Map();
  try {
    if (sessionId) globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(storageValue()));
    else globalThis.localStorage?.removeItem(STORAGE_KEY);
  } catch {
    // Nothing to persist.
  }
  notify();
}
