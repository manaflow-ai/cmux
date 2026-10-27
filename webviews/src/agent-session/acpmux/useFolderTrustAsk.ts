import { useCallback, useEffect, useRef, useState } from "react";
import {
  readFolderTrust,
  readTrust,
  sessionTrust,
  type FolderTrust,
  type TrustLevel,
  type TrustRepo,
  type TrustSource,
} from "./folderTrust";
import type { StringKey } from "./i18n";
import { trustRefusal } from "./direct";

/// The chat's trust question: "ask" while the folder reads as unknown for the chat's agent, then
/// the user's answer with its Undo, or "failed" when saving it didn't. `repo`: the repository
/// holding the folder (the question offers to trust it whole); `via`: the folder the answer was
/// made for when not this one (the repository, or a parent folder).
export type FolderTrustAsk = { cwd: string; repo?: TrustRepo; via?: string } & (
  | { state: "ask" | "failed" | "remote" }
  | { state: "decided"; level: Exclude<TrustLevel, "unknown"> }
);

/// Where the folder's answer lives, read or answered last: the trusted grant names it, and Undo
/// forgets the answer there.
/// `recorded: false`: no answer of the person's holds it (an auto-trust rule, an agent's own level).
export type TrustScope = { cwd: string; via?: string; repo?: TrustRepo; recorded?: false };

/// The folder an answer for `ask` is recorded for: the repository when the folder is in one (one
/// answer covers every worktree of it), else the folder.
export function answerFolder(ask: { cwd: string; repo?: TrustRepo }, scope: "repo" | "folder"): string {
  return scope === "repo" && ask.repo ? ask.repo.root : ask.cwd;
}

/// Why Send is off; no `reason` while the folder's trust is still being read. `shownAbove`: the
/// question over the card already says it, so the card draws no caption (Send's tooltip keeps it).
export type SendBlock = { reason?: StringKey; shownAbove?: boolean };

/// The last answer read for each folder, kept for the next chat there (another tab, workspace, or
/// a new page from the pool): a switch draws the folder's known trust from its first render, and
/// the read that follows only refreshes it (Leo 2026-10-19: the permission UI flickered on every
/// switch while each read was in flight). acpmux still refuses a prompt the folder's current
/// trust does not allow (`trust_gate.rs`), and that refusal reads the folder again.
const KNOWN_KEY = "cmux.agentPane.folderTrust.v1";
const KNOWN_LIMIT = 200;
let known: Map<string, FolderTrust> | undefined;

function knownTrust(): Map<string, FolderTrust> {
  if (known) return known;
  known = new Map();
  try {
    const saved = JSON.parse(window.localStorage.getItem(KNOWN_KEY) ?? "[]") as unknown;
    if (Array.isArray(saved))
      for (const value of saved) {
        const trust = readTrust(value);
        if (trust) known.set(trust.cwd, trust);
      }
  } catch {
    // No storage (a private page, a test): this page's reads still count.
  }
  return known;
}

function rememberTrust(cwd: string, trust: FolderTrust | undefined) {
  const map = knownTrust();
  map.delete(cwd);
  if (trust) map.set(cwd, trust);
  while (map.size > KNOWN_LIMIT) map.delete(map.keys().next().value!);
  try {
    window.localStorage.setItem(KNOWN_KEY, JSON.stringify([...map.values()]));
  } catch {
    // Kept for this page only.
  }
}

/// Drops the kept answers of the folders under `folder` (its repository's answer just changed):
/// their next chat reads them again instead of drawing a stale answer first.
function forgetUnder(folder: string) {
  const map = knownTrust();
  const inside = (cwd: string) => cwd === folder || cwd.startsWith(folder.endsWith("/") ? folder : `${folder}/`);
  for (const [cwd, trust] of map)
    if (inside(cwd) || trust.via === folder || trust.repo?.root === folder) map.delete(cwd);
  try {
    window.localStorage.setItem(KNOWN_KEY, JSON.stringify([...map.values()]));
  } catch {
    // Kept for this page only.
  }
}

/// What a folder's trust shows for a chat with `family`: the question, a decision, or trusted.
function shownTrust(trust: FolderTrust, cwd: string, family: string | undefined, canAnswer: boolean) {
  const level = sessionTrust(trust, family);
  const scope = {
    cwd,
    ...(trust.repo ? { repo: trust.repo } : {}),
    ...(trust.via ? { via: trust.via } : {}),
  };
  return {
    ask:
      level === "unknown"
        ? ({ ...scope, state: canAnswer ? "ask" : "remote" } as FolderTrustAsk)
        : level === "untrusted"
          ? ({ ...scope, state: "decided", level } as FolderTrustAsk)
          : undefined,
    trusted: level === "trusted",
    scope: { ...scope, ...(trust.decided === false || trust.auto ? { recorded: false } : {}) } as TrustScope,
  };
}

function sameAsk(left: FolderTrustAsk | undefined, right: FolderTrustAsk | undefined): boolean {
  return (
    left === right ||
    (left !== undefined &&
      right !== undefined &&
      left.cwd === right.cwd &&
      left.state === right.state &&
      left.via === right.via &&
      left.repo?.root === right.repo?.root &&
      left.repo?.worktree === right.repo?.worktree &&
      (left.state === "decided" ? left.level : undefined) === (right.state === "decided" ? right.level : undefined))
  );
}

/// The trust question for the chat in `cwd`, asked as soon as the folder is known (a new chat
/// before its first prompt). No prompt goes while it is open or after Don't trust: `blocked`
/// says why, and acpmux refuses the prompt too (`trust_gate.rs`). Another chat or folder asks
/// again; Trust's answer goes once the user sends their next prompt (`prompts` grows), and
/// Don't trust's stays with its Undo.
///
/// A refusal for a folder the pane did not know (a new chat whose folder the host filled in)
/// asks about the folder acpmux named (`refused`), and Trust then sends the held prompt again
/// (one gesture); Don't trust leaves it in the composer with the reason.
export function useFolderTrustAsk(
  source: TrustSource,
  chat: { sessionId?: string; cwd?: string; family?: string; prompts: number },
  canAnswer = true,
  /// The chat's folder is on this computer: only then is its answer kept by path for the next chat.
  local = true,
) {
  const [ask, setAsk] = useState<FolderTrustAsk>();
  const [trusted, setTrusted] = useState(false);
  const [scope, setScope] = useState<TrustScope>();
  const [justTrusted, setJustTrusted] = useState(false);
  const undoTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [reading, setReading] = useState(false);
  /// Bumped by `recheck` (acpmux refused a prompt the pane did not hold): read the folder again.
  const [reads, setReads] = useState(0);
  /// The folder acpmux named in a trust refusal for this chat, and the prompt to send after Trust.
  const [refusal, setRefusal] = useState<{ sessionId?: string; cwd?: string }>();
  const resend = useRef<{ again: () => void; declined?: () => void } | undefined>(undefined);
  /// What acpmux's last trust refusal for this chat said of its folder: the question draws from it
  /// when the folder's read gets no answer in time (a peer's folder, read over the peer link).
  const refusedTrust = useRef<{ sessionId?: string; cwd: string; level: TrustLevel } | undefined>(undefined);
  const { sessionId, family, prompts } = chat;
  const cwd = chat.cwd ?? (refusal && refusal.sessionId === sessionId ? refusal.cwd : undefined);
  // The chat a reply belongs to; a late reply for another one is dropped.
  const current = useRef({ sessionId, cwd });
  current.current = { sessionId, cwd };
  const decidedAt = useRef<number | undefined>(undefined);
  // One answer at a time: a second click while the first saves is ignored.
  const saving = useRef(false);
  /// Answers saved per folder: a read of that folder that started before one is older than the
  /// answer and is dropped. An answer for another folder leaves the read standing.
  const answers = useRef(new Map<string, number>());
  // A chat that can't answer here (a peer's or remote one) is another machine's folder: no record.
  // A remote or peer folder can share a local path: its answer is never kept by path.
  const remembers = canAnswer && local;

  /// The folder's trust as last read or answered here, for another chat or agent in the same folder.
  const lastRead = useRef<{ cwd: string; trust: FolderTrust } | undefined>(undefined);
  /// The family a read applies (the read is the folder's; each agent's level comes from it).
  const familyNow = useRef(family);
  familyNow.current = family;

  // Another chat, folder or agent: drawn in this render, so no frame shows it unread. The same
  // folder keeps its answer and is not read again (Leo 2026-10-19); another agent there takes its
  // own level from that answer. Another folder draws from its known trust, reading only when the
  // pane never read it.
  const chatKey = JSON.stringify([sessionId, cwd, family, canAnswer]);
  const folderKey = JSON.stringify([cwd, canAnswer]);
  const [shownChat, setShownChat] = useState<{ chat: string; folder: string }>();
  if (shownChat?.chat !== chatKey) {
    const sameFolder = shownChat?.folder === folderKey;
    setShownChat({ chat: chatKey, folder: folderKey });
    setJustTrusted(false);
    const last = lastRead.current;
    const known = last && sameFolder && last.cwd === cwd ? last.trust : undefined;
    if (sameFolder && known && cwd) {
      const shown = shownTrust(known, cwd, family, canAnswer);
      setAsk(shown.ask);
      setTrusted(shown.trusted);
      setScope(shown.scope);
    } else if (sameFolder) {
      // The answer belongs to the last chat: another one starts with the folder's question or none.
      setAsk((was) => (was?.state === "decided" && was.level === "trusted" ? undefined : was));
    } else {
      const trust = cwd && remembers ? knownTrust().get(cwd) : undefined;
      const shown =
        trust && cwd ? shownTrust(trust, cwd, family, canAnswer) : { ask: undefined, trusted: false, scope: undefined };
      setAsk(shown.ask);
      setTrusted(shown.trusted);
      setScope(shown.scope);
      setReading(Boolean(cwd) && !trust);
    }
  }
  useEffect(() => {
    clearTimeout(undoTimer.current);
    decidedAt.current = undefined;
  }, [sessionId, cwd]);
  useEffect(() => {
    if (!cwd) return;
    let live = true;
    const answered = answers.current.get(cwd) ?? 0;
    void readFolderTrust(source, cwd).then((trust) => {
      if (!live) return;
      setReading(false);
      // An answer saved since this read began is newer than it: the answer stands.
      if ((answers.current.get(cwd) ?? 0) !== answered) return;
      // A folder the pane can't read is not asked about (a known answer stays); acpmux still
      // refuses its prompts, and once it has, its refusal draws the question.
      if (!trust) {
        const said = refusedTrust.current;
        if (said && said.sessionId === current.current.sessionId && said.cwd === cwd) {
          const shown = shownTrust({ cwd, level: said.level }, cwd, familyNow.current, canAnswer);
          setAsk((was) => (sameAsk(was, shown.ask) ? was : shown.ask));
        }
        return;
      }
      if (remembers) rememberTrust(cwd, trust);
      lastRead.current = { cwd, trust };
      const shown = shownTrust(trust, cwd, familyNow.current, canAnswer);
      setAsk((was) => (sameAsk(was, shown.ask) ? was : shown.ask));
      setTrusted(shown.trusted);
      setScope(shown.scope);
    });
    return () => {
      live = false;
    };
  }, [source, cwd, reads, canAnswer, remembers]);

  useEffect(() => {
    if (
      ask?.state === "decided" &&
      ask.level === "trusted" &&
      decidedAt.current !== undefined &&
      prompts > decidedAt.current
    )
      setAsk(undefined);
  }, [ask, prompts]);
  useEffect(() => () => clearTimeout(undoTimer.current), []);

  /// Records `level` for `folder` (the chat's folder, its repository, or for Undo the folder the
  /// answer was made for): the chat's folder takes it from there.
  const save = useCallback(
    async (level: TrustLevel, folder?: string) => {
      if ((!ask && !cwd) || saving.current) return;
      saving.current = true;
      const asked = { sessionId, cwd: ask?.cwd ?? cwd! };
      const repo = ask?.repo ?? (scope?.cwd === asked.cwd ? scope.repo : undefined);
      const recorded = folder ?? asked.cwd;
      const stillHere = () => current.current.sessionId === asked.sessionId && current.current.cwd === asked.cwd;
      try {
        await source.set(recorded, level);
        refusedTrust.current = undefined;
        for (const key of new Set([asked.cwd, recorded])) answers.current.set(key, (answers.current.get(key) ?? 0) + 1);
        // Undo leaves each agent's own level to answer: the next read says which.
        const where = { ...(repo ? { repo } : {}), ...(recorded !== asked.cwd ? { via: recorded } : {}) };
        const answer: FolderTrust | undefined =
          level === "unknown" ? undefined : { cwd: asked.cwd, level, decided: true, ...where };
        if (remembers) {
          // Another folder's kept answer may be the one just changed (the repository's): read again.
          if (recorded !== asked.cwd) forgetUnder(recorded);
          rememberTrust(asked.cwd, answer);
        }
        lastRead.current = answer && { cwd: asked.cwd, trust: answer };
        if (!stillHere()) return;
        decidedAt.current = level === "unknown" ? undefined : prompts;
        setTrusted(level === "trusted");
        setScope(level === "unknown" ? { cwd: asked.cwd, ...(repo ? { repo } : {}) } : { cwd: asked.cwd, ...where });
        clearTimeout(undoTimer.current);
        setJustTrusted(level === "trusted");
        if (level === "trusted") undoTimer.current = setTimeout(() => setJustTrusted(false), 4000);
        setAsk(
          level === "unknown"
            ? { cwd: asked.cwd, ...(repo ? { repo } : {}), state: "ask" }
            : { cwd: asked.cwd, ...where, state: "decided", level },
        );
        // The prompt acpmux refused goes now that the folder is trusted; another answer keeps it.
        const held = resend.current;
        resend.current = undefined;
        if (level === "trusted") held?.again();
        else held?.declined?.();
      } catch {
        if (stillHere()) setAsk({ cwd: asked.cwd, state: "failed" });
      } finally {
        saving.current = false;
      }
    },
    [ask, cwd, scope, source, sessionId, prompts, remembers],
  );

  const blocked: SendBlock | undefined = reading
    ? {}
    : ask?.state === "ask" || ask?.state === "failed"
      ? { reason: "trust.answerFirst", shownAbove: true }
      : ask?.state === "remote"
        ? { reason: "trust.remote" }
        : ask?.state === "decided" && ask.level === "untrusted"
          ? { reason: "trust.notTrustedNoPrompts" }
          : undefined;

  return {
    ask,
    /// The trust question or Don't trust holds the chat's other asks (permission, secret, tool
    /// cards): one question at a time. A read in flight asks nothing, so it holds nothing; the asks
    /// keep their place while it reads (a chat switch), and only Send waits.
    holdsAsks: Boolean(blocked?.reason),
    trusted,
    /// Where the folder's answer lives (its repository, a parent folder), for the trusted grant.
    scope,
    justTrusted,
    blocked,
    /// Trust only the chat's folder.
    trust: () => void save("trusted"),
    /// Trust the repository holding the folder: every worktree of it takes the answer.
    trustRepo: () => void save("trusted", ask ? answerFolder(ask, "repo") : undefined),
    /// Not now: recorded where Trust repo would be, so the next worktree does not ask again.
    distrust: () => void save("untrusted", ask ? answerFolder(ask, "repo") : undefined),
    /// Back to unknown: acpmux forgets its record where the answer was made (the repository, a
    /// parent folder, or the folder) and each agent's own level answers.
    undo: () => void save("unknown", ask?.via ?? (scope?.cwd === cwd ? scope?.via : undefined)),
    /// Takes a refusal from acpmux: for its folder trust it reads the folder it named again (the
    /// question shows), keeps `again` to send after Trust, and is true; any other refusal is false.
    refused: useCallback(
      (error: unknown, again?: () => void, declined?: () => void): boolean => {
        const said = trustRefusal(error);
        if (!said) return false;
        const named = said.cwd;
        if (named) setRefusal({ sessionId, cwd: named });
        const refusedFolder = named ?? cwd;
        refusedTrust.current = refusedFolder
          ? { sessionId, cwd: refusedFolder, level: said.reason === "trust.untrusted" ? "untrusted" : "unknown" }
          : undefined;
        // acpmux says the folder is not trusted now: its record is stale, and Send waits for the read.
        for (const folder of [named, cwd]) if (typeof folder === "string" && folder) rememberTrust(folder, undefined);
        lastRead.current = undefined;
        setTrusted(false);
        setReading(true);
        // A refusal without its own re-run (a prompt the client routed first) keeps the one set.
        if (again) resend.current = { again, declined };
        setReads((count) => count + 1);
        return true;
      },
      [sessionId, cwd],
    ),
  };
}
