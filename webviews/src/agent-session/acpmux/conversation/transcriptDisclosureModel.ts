import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import { type TranscriptView } from "./transcriptView";

/**
 * Disclosure state for transcript details. Rows are virtualized, so the state cannot live in a
 * component's local `useState`: a command that scrolls out of the viewport would forget whether
 * the reader opened it. The key is the acpmux session plus a stable tool or group id.
 */
const STORAGE_KEY = "cmux.acpmux.transcriptDisclosure";
const SESSION_LIMIT = 40;
const DISCLOSURE_LIMIT = 600;
export const DEFAULT_SESSION = "__transcript__";

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

/**
 * Returns a persisted disclosure value and a React-compatible setter. `verboseOpen` opens it by
 * default in the Verbose view (a tool's output). The reader's toggles are kept per view, so each
 * view starts from its own defaults and switching back finds the old toggles where they were.
 * `inherits`: keys of the disclosures this one replaced; one the reader opened opens this one until
 * the reader sets this one; `passesDown` (a run's line) hands the reader's choice to those they set
 * (Leo, 2026-11-07: "I opened up, expanded the tool calls, and then it closed on by itself").
 */
export function useTranscriptDisclosure(
  key: string,
  defaultOpen = false,
  verboseOpen = false,
  inherits: readonly string[] = NONE,
  passesDown = false,
  members: readonly string[] = NONE,
): [boolean, DisclosureSetter] {
  const view = useContext(ViewContext);
  const sessionId = useDisclosureSessionId();
  const opens = defaultOpen || (verboseOpen && view === "verbose");
  const from = inherits.join("\n");
  // `members`: the calls a fold holds (`callDisclosureKey`). One the reader opened keeps the fold open
  // until the reader sets the fold itself, as `inherits` does, but the fold's own choice never passes
  // down to them: closing a run's line keeps the calls in it as the reader left them.
  const held = members.join("\n");
  const getSnapshot = useCallback(
    () => read(sessionId, key) ?? (opens || inherited(sessionId, from) || inherited(sessionId, held)),
    [sessionId, key, opens, from, held],
  );
  const open = useSyncExternalStore(subscribe, getSnapshot, () => opens);
  const setOpen = useCallback<DisclosureSetter>(
    (value) => {
      const current = read(sessionId, key) ?? (opens || inherited(sessionId, from) || inherited(sessionId, held));
      const next = typeof value === "function" ? value(current) : value;
      // A run's line the reader set takes the place of the group lines it inherits from: one they had
      // set takes the same choice, so a run line they closed never reopens as its group's line when the
      // run splits back into groups. A line they never set keeps its own default, and a group's line
      // passes nothing up, so closing one group never closes its sibling through the run's key.
      if (passesDown && from !== "")
        for (const other of from.split("\n")) if (read(sessionId, other) !== undefined) save(sessionId, other, next);
      save(sessionId, key, next);
    },
    [sessionId, key, opens, from, held, passesDown],
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
export const callDisclosureKey = (id: string) => `row:${id}`;

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
