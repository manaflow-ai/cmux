import { useCallback, useEffect, useRef, useState } from "react";
import {
  readFolderTrust,
  readTrust,
  sessionTrust,
  type FolderTrust,
  type TrustLevel,
  type TrustSource,
} from "./folderTrust";
import type { StringKey } from "./i18n";
import { isTrustRefusal } from "./direct";

/// The chat's trust question: "ask" while the folder reads as unknown for the chat's agent, then
/// the user's answer with its Undo, or "failed" when saving it didn't.
export type FolderTrustAsk =
  | { cwd: string; state: "ask" | "failed" | "remote" }
  | { cwd: string; state: "decided"; level: Exclude<TrustLevel, "unknown"> };

/// Why Send is off; no `reason` while the folder's trust is still being read.
export type SendBlock = { reason?: StringKey };

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

/// What a folder's trust shows for a chat with `family`: the question, a decision, or trusted.
function shownTrust(trust: FolderTrust, cwd: string, family: string | undefined, canAnswer: boolean) {
  const level = sessionTrust(trust, family);
  return {
    ask:
      level === "unknown"
        ? ({ cwd, state: canAnswer ? "ask" : "remote" } as FolderTrustAsk)
        : level === "untrusted"
          ? ({ cwd, state: "decided", level } as FolderTrustAsk)
          : undefined,
    trusted: level === "trusted",
  };
}

function sameAsk(left: FolderTrustAsk | undefined, right: FolderTrustAsk | undefined): boolean {
  return (
    left === right ||
    (left !== undefined &&
      right !== undefined &&
      left.cwd === right.cwd &&
      left.state === right.state &&
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
  const [justTrusted, setJustTrusted] = useState(false);
  const undoTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [reading, setReading] = useState(false);
  /// Bumped by `recheck` (acpmux refused a prompt the pane did not hold): read the folder again.
  const [reads, setReads] = useState(0);
  /// The folder acpmux named in a trust refusal for this chat, and the prompt to send after Trust.
  const [refusal, setRefusal] = useState<{ sessionId?: string; cwd?: string }>();
  const resend = useRef<(() => void) | undefined>(undefined);
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
    } else if (sameFolder) {
      // The answer belongs to the last chat: another one starts with the folder's question or none.
      setAsk((was) => (was?.state === "decided" && was.level === "trusted" ? undefined : was));
    } else {
      const trust = cwd && remembers ? knownTrust().get(cwd) : undefined;
      const shown = trust && cwd ? shownTrust(trust, cwd, family, canAnswer) : { ask: undefined, trusted: false };
      setAsk(shown.ask);
      setTrusted(shown.trusted);
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
      // refuses its prompts.
      if (!trust) return;
      if (remembers) rememberTrust(cwd, trust);
      lastRead.current = { cwd, trust };
      const shown = shownTrust(trust, cwd, familyNow.current, canAnswer);
      setAsk((was) => (sameAsk(was, shown.ask) ? was : shown.ask));
      setTrusted(shown.trusted);
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

  const save = useCallback(
    async (level: TrustLevel) => {
      if ((!ask && !cwd) || saving.current) return;
      saving.current = true;
      const asked = { sessionId, cwd: ask?.cwd ?? cwd! };
      const stillHere = () => current.current.sessionId === asked.sessionId && current.current.cwd === asked.cwd;
      try {
        await source.set(asked.cwd, level);
        answers.current.set(asked.cwd, (answers.current.get(asked.cwd) ?? 0) + 1);
        // Undo leaves each agent's own level to answer: the next read says which.
        const answer: FolderTrust | undefined =
          level === "unknown" ? undefined : { cwd: asked.cwd, level, decided: true };
        if (remembers) rememberTrust(asked.cwd, answer);
        lastRead.current = answer && { cwd: asked.cwd, trust: answer };
        if (!stillHere()) return;
        decidedAt.current = level === "unknown" ? undefined : prompts;
        setTrusted(level === "trusted");
        clearTimeout(undoTimer.current);
        setJustTrusted(level === "trusted");
        if (level === "trusted") undoTimer.current = setTimeout(() => setJustTrusted(false), 4000);
        setAsk(level === "unknown" ? { cwd: asked.cwd, state: "ask" } : { cwd: asked.cwd, state: "decided", level });
        // The prompt acpmux refused goes now that the folder is trusted; another answer keeps it.
        const held = resend.current;
        resend.current = undefined;
        if (level === "trusted") held?.();
      } catch {
        if (stillHere()) setAsk({ cwd: asked.cwd, state: "failed" });
      } finally {
        saving.current = false;
      }
    },
    [ask, cwd, source, sessionId, prompts, remembers],
  );

  const blocked: SendBlock | undefined = reading
    ? {}
    : ask?.state === "ask" || ask?.state === "failed"
      ? { reason: "trust.answerFirst" }
      : ask?.state === "remote"
        ? { reason: "trust.remote" }
        : ask?.state === "decided" && ask.level === "untrusted"
          ? { reason: "trust.untrustedNoPrompts" }
          : undefined;

  return {
    ask,
    /// The trust question or Don't trust holds the chat's other asks (permission, secret, tool
    /// cards): one question at a time. A read in flight asks nothing, so it holds nothing; the asks
    /// keep their place while it reads (a chat switch), and only Send waits.
    holdsAsks: Boolean(blocked?.reason),
    trusted,
    justTrusted,
    blocked,
    trust: () => void save("trusted"),
    distrust: () => void save("untrusted"),
    /// Back to unknown: acpmux forgets its record and each agent's own level answers.
    undo: () => void save("unknown"),
    /// Takes a refusal from acpmux: for its folder trust it reads the folder it named again (the
    /// question shows), keeps `again` to send after Trust, and is true; any other refusal is false.
    refused: useCallback(
      (error: unknown, again?: () => void): boolean => {
        if (!isTrustRefusal(error)) return false;
        const named = (error as { cwd?: unknown }).cwd;
        if (typeof named === "string" && named) setRefusal({ sessionId, cwd: named });
        // acpmux says the folder is not trusted now: its record is stale, and Send waits for the read.
        for (const folder of [named, cwd]) if (typeof folder === "string" && folder) rememberTrust(folder, undefined);
        lastRead.current = undefined;
        setTrusted(false);
        setReading(true);
        // A refusal without its own re-run (a prompt the client routed first) keeps the one set.
        if (again) resend.current = again;
        setReads((count) => count + 1);
        return true;
      },
      [sessionId, cwd],
    ),
  };
}
