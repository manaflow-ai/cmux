// Back to before this turn in a chat on this machine (LocalRewind.tsx): acpmux takes a git
// checkpoint before each prompt when `agents.turnCheckpoints` is on and names it on that turn's
// `turn_result` (`rewindCheckpointId`, or `rewindCheckpointError` when it could not take one: not a
// git repository). A prompt whose turn ended with either field rewinds; with the setting off no
// turn has one and nothing draws. The rewind itself is acpmux's `_acpmux/rewind` (a dry run when the
// confirm opens, which counts the files and says why they can't be reset), and its Undo is
// `_acpmux/rewind_undo`. This file reads the wire; the pane's flow is App.tsx's `localRewind`.
import type { AcpmuxRow } from "../model";
import type { StringKey, Translate } from "../i18n";

/// What a turn summary says of its turn's rewind checkpoint: `checkpointId`, the checkpoint taken
/// before its prompt; `error`, why none was taken. Either makes the prompt rewindable.
export type TurnRewind = { checkpointId?: string; error?: string };

const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/// The rewind fields of a `turn_result` message (or a row body that carries them as `rewind`),
/// undefined from an acpmux that took no rewind checkpoint (the setting off, an older acpmux).
export function readTurnRewind(message: unknown): TurnRewind | undefined {
  if (!message || typeof message !== "object") return undefined;
  const raw = message as Record<string, unknown>;
  const nested = raw.rewind && typeof raw.rewind === "object" ? (raw.rewind as Record<string, unknown>) : undefined;
  const checkpointId = text(raw.rewindCheckpointId) ?? text(nested?.checkpointId);
  const error = text(raw.rewindCheckpointError) ?? text(nested?.error);
  if (!checkpointId && !error) return undefined;
  return { ...(checkpointId ? { checkpointId } : {}), ...(error ? { error } : {}) };
}

const opensTurn = (row: AcpmuxRow) =>
  row.kind === "user" && !row.failed && !row.queued && !row.pending && row.steer !== "waiting";

/// The prompt's own acpmux seq (`_acpmux/rewind {seq}`): the seq its echo came with, else the one
/// its `user-<seq>` row id names. Undefined for a prompt acpmux has not logged.
export function promptSeqOf(row: AcpmuxRow): number | undefined {
  if (typeof row.promptSeq === "number" && row.promptSeq >= 1) return row.promptSeq;
  const match = /^user-(\d+)$/.exec(row.id);
  return match ? Number(match[1]) : undefined;
}

/// The prompts that rewind here, each with its seq: a prompt that opened a turn whose summary
/// carries the turn's rewind fields. A prompt with no seq, and one whose turn has not ended, has none.
export function localRewindPrompts(rows: readonly AcpmuxRow[]): Map<string, number> {
  const ready = new Map<string, number>();
  let open: AcpmuxRow | undefined;
  for (const row of rows) {
    if (row.kind === "turnSummary") {
      if (open && row.rewind) {
        const seq = promptSeqOf(open);
        if (seq !== undefined) ready.set(open.id, seq);
      }
      open = undefined;
    } else if (open === undefined && opensTurn(row)) open = row;
  }
  return ready;
}

/// The same prompts as a string, so the App rebuilds its actions only when they change.
export const localRewindKey = (ready: ReadonlyMap<string, number>) =>
  [...ready].map(([id, seq]) => `${id}:${seq}`).join(",");

/// The prompts back from `localRewindKey`.
export function localRewindMap(key: string): Map<string, number> {
  const ready = new Map<string, number>();
  for (const entry of key ? key.split(",") : []) {
    const at = entry.lastIndexOf(":");
    ready.set(entry.slice(0, at), Number(entry.slice(at + 1)));
  }
  return ready;
}

/// Why acpmux won't reset the files (dry run `filesBlocked.reason`, an error's `data.reason`).
export type RewindBlock = "shared" | "no_checkpoint" | "base_changed" | "not_git" | "unavailable";
const BLOCKS: readonly RewindBlock[] = ["shared", "no_checkpoint", "base_changed", "not_git", "unavailable"];

/// A dry run's answer, as the confirm reads it.
export type RewindDryRun = {
  /// How the conversation goes back: acpmux's own rewind, a fork through the turn before, or not at all.
  conversation: "native" | "fork" | null;
  files: { checkpointId: string; total: number; paths: string[]; baseChanged: boolean; complete: boolean } | null;
  filesBlocked?: { reason: RewindBlock; message: string; sharedWith?: { sessionId: string; title?: string }[] };
};

/// A rewind's answer: `sessionId`, the rewound chat (a new fork) when the conversation went back;
/// `prompt`, the prompt's text to put back in the composer; `undo`, what Undo needs.
export type RewindApplied = {
  sessionId?: string;
  prompt?: { text: string };
  undo: { sessionId: string; safetyCheckpointId?: string };
  filesRestored: number;
};

/// Which parts go back.
export type RewindChoice = { conversation: boolean; files: boolean };

const block = (value: unknown): RewindBlock =>
  BLOCKS.includes(value as RewindBlock) ? (value as RewindBlock) : "unavailable";

export function parseDryRun(value: unknown): RewindDryRun {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const conversation = raw.conversation === "native" || raw.conversation === "fork" ? raw.conversation : null;
  const filesRaw = raw.files && typeof raw.files === "object" ? (raw.files as Record<string, unknown>) : undefined;
  const files =
    filesRaw && text(filesRaw.checkpointId)
      ? {
          checkpointId: String(filesRaw.checkpointId),
          total: typeof filesRaw.total === "number" && filesRaw.total >= 0 ? filesRaw.total : 0,
          paths: Array.isArray(filesRaw.paths)
            ? filesRaw.paths.filter((path): path is string => typeof path === "string")
            : [],
          baseChanged: filesRaw.baseChanged === true,
          complete: filesRaw.complete !== false,
        }
      : null;
  const blockedRaw =
    raw.filesBlocked && typeof raw.filesBlocked === "object"
      ? (raw.filesBlocked as Record<string, unknown>)
      : undefined;
  const sharedWith = Array.isArray(blockedRaw?.sharedWith)
    ? blockedRaw.sharedWith.flatMap((chat: unknown) => {
        const entry = (chat && typeof chat === "object" ? chat : {}) as Record<string, unknown>;
        const sessionId = text(entry.sessionId);
        if (!sessionId) return [];
        const title = text(entry.title);
        return [{ sessionId, ...(title ? { title } : {}) }];
      })
    : undefined;
  return {
    conversation,
    files,
    ...(blockedRaw
      ? {
          filesBlocked: {
            reason: block(blockedRaw.reason),
            message: text(blockedRaw.message) ?? "",
            ...(sharedWith?.length ? { sharedWith } : {}),
          },
        }
      : {}),
  };
}

export function parseApplied(value: unknown, original: string): RewindApplied {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const undoRaw = (raw.undo && typeof raw.undo === "object" ? raw.undo : {}) as Record<string, unknown>;
  const prompt = raw.prompt && typeof raw.prompt === "object" ? (raw.prompt as Record<string, unknown>) : undefined;
  const sessionId = text(raw.sessionId);
  const safetyCheckpointId = text(undoRaw.safetyCheckpointId);
  return {
    ...(sessionId ? { sessionId } : {}),
    ...(prompt && typeof prompt.text === "string" ? { prompt: { text: prompt.text } } : {}),
    undo: { sessionId: text(undoRaw.sessionId) ?? original, ...(safetyCheckpointId ? { safetyCheckpointId } : {}) },
    filesRestored: typeof raw.filesRestored === "number" ? raw.filesRestored : 0,
  };
}

/// What the confirm's files choice offers, from the dry run: the count when they can be reset, else
/// why not. `none`: the checkpoint holds no change to put back.
export type FilesOffer =
  | { kind: "available"; total: number; baseChanged: boolean; complete: boolean }
  | { kind: "blocked"; reason: RewindBlock | "none"; sharedWith?: { sessionId: string; title?: string }[] };

export function filesOffer(dry: RewindDryRun | undefined): FilesOffer | undefined {
  if (!dry) return undefined;
  if (dry.filesBlocked)
    return {
      kind: "blocked",
      reason: dry.filesBlocked.reason,
      ...(dry.filesBlocked.sharedWith ? { sharedWith: dry.filesBlocked.sharedWith } : {}),
    };
  if (!dry.files) return { kind: "blocked", reason: "no_checkpoint" };
  if (dry.files.total === 0) return { kind: "blocked", reason: "none" };
  return {
    kind: "available",
    total: dry.files.total,
    baseChanged: dry.files.baseChanged,
    complete: dry.files.complete,
  };
}

const BLOCK_TEXT: Record<RewindBlock | "none" | "fork.unsupported", StringKey> = {
  shared: "rewind.blocked.shared",
  no_checkpoint: "rewind.blocked.noCheckpoint",
  base_changed: "rewind.blocked.baseChanged",
  not_git: "rewind.blocked.notGit",
  unavailable: "rewind.blocked.unavailable",
  none: "rewind.blocked.none",
  "fork.unsupported": "rewind.blocked.forkUnsupported",
};

/// Why the files can't be reset, in words: a shared folder names the other chat when acpmux gave its title.
export function blockedText(
  t: Translate,
  offer:
    | Extract<FilesOffer, { kind: "blocked" }>
    | { reason: RewindBlock | "none" | "fork.unsupported"; sharedWith?: { title?: string }[] },
): string {
  const title = offer.reason === "shared" ? offer.sharedWith?.find((chat) => chat.title)?.title : undefined;
  return title ? t("rewind.blocked.sharedWith", { title }) : t(BLOCK_TEXT[offer.reason]);
}

/// A failed rewind's words: its reason when acpmux named one this pane knows.
export function failedText(t: Translate, error: unknown): string {
  const reason = (error as { reason?: unknown } | null)?.reason;
  if (typeof reason === "string" && (BLOCKS.includes(reason as RewindBlock) || reason === "fork.unsupported"))
    return t("rewind.failedReason", { reason: t(BLOCK_TEXT[reason as RewindBlock | "fork.unsupported"]) });
  return t("rewind.failed");
}

/// The choice the confirm opens with: the conversation only, unless the conversation can't go back
/// and the files can (a files-only rewind).
export function initialChoice(dry: RewindDryRun | undefined): RewindChoice {
  if (dry && dry.conversation === null && filesOffer(dry)?.kind === "available")
    return { conversation: false, files: true };
  return { conversation: true, files: false };
}

/// What Confirm sends: at least one part, and files only where the dry run offered them.
export function canConfirm(dry: RewindDryRun | undefined, choice: RewindChoice): boolean {
  if (!dry) return false;
  const conversation = choice.conversation && dry.conversation !== null;
  const files = choice.files && filesOffer(dry)?.kind === "available";
  if (choice.conversation && dry.conversation === null) return false;
  if (choice.files && !files) return false;
  return conversation || files;
}

/// The Undo the notice after a rewind offers: `original`, the chat before it; `rewound`, the fork
/// the pane shows now (none for a files-only rewind); `safetyCheckpointId`, the files as they were.
export type RewindUndo = {
  original: string;
  rewound?: string;
  safetyCheckpointId?: string;
  conversation: boolean;
  files: number;
};

/// A rewind that failed with its files still reset (the conversation could not go back, and putting
/// the files back failed too): the Undo that still puts them back, from the error's `undo`.
export function undoAfterFailedRewind(error: unknown, original: string): RewindUndo | undefined {
  const data = (error as { data?: unknown } | null)?.data as
    | { filesRolledBack?: unknown; filesRestored?: unknown; undo?: { safetyCheckpointId?: unknown } }
    | undefined;
  const safety = data?.undo?.safetyCheckpointId;
  if (data?.filesRolledBack !== false || typeof safety !== "string" || !safety) return undefined;
  const files = typeof data.filesRestored === "number" ? data.filesRestored : 0;
  return { original, conversation: false, safetyCheckpointId: safety, files };
}

/// The steps a rewind's Undo takes: files back first (they are the chat's, wherever it shows), then
/// the original chat in the pane.
export async function undoRewind(
  undo: RewindUndo,
  io: {
    restoreFiles(sessionId: string, safetyCheckpointId: string): Promise<unknown>;
    open(sessionId: string): Promise<unknown>;
  },
): Promise<void> {
  if (undo.safetyCheckpointId) await io.restoreFiles(undo.original, undo.safetyCheckpointId);
  if (undo.rewound) await io.open(undo.original);
}

/// The steps a confirmed rewind takes: acpmux's rewind of prompt `seq`; then a conversation that
/// went back opens its fork in this pane and gets the prompt's text in the composer, unsent. Settles
/// with the Undo the notice offers.
export async function applyRewind(
  seq: number,
  choice: RewindChoice,
  io: {
    original: string;
    rewind(seq: number, choice: RewindChoice): Promise<unknown>;
    open(sessionId: string): Promise<unknown>;
    restorePrompt(text: string): void;
  },
): Promise<RewindUndo> {
  const applied = parseApplied(await io.rewind(seq, choice), io.original);
  const rewound = applied.sessionId && applied.sessionId !== applied.undo.sessionId ? applied.sessionId : undefined;
  if (rewound) await io.open(rewound);
  if (choice.conversation && applied.prompt?.text) io.restorePrompt(applied.prompt.text);
  return {
    original: applied.undo.sessionId,
    conversation: choice.conversation,
    ...(rewound ? { rewound } : {}),
    ...(applied.undo.safetyCheckpointId ? { safetyCheckpointId: applied.undo.safetyCheckpointId } : {}),
    files: applied.filesRestored,
  };
}

/// The rewind's words in the notice (`rewind.done` and friends) for what went back.
export function undoNoticeKey(undo: RewindUndo): StringKey {
  return undo.conversation ? "rewind.done" : "rewind.doneFiles";
}
