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

/// What `visitOf` records for a request made from a stale render: no visit ever matches it.
const STALE_VISIT = "stale:";

/// A folder question, or its answer saving (Use was clicked), holds only the chat it was asked in:
/// the same session id and, when the client named one, the same visit. Two fresh chats share no
/// session id, so the visit (`trustVisit` in App.tsx) tells them apart.
export function inThisVisit(
  held: false | undefined | { sessionId?: string; visit?: string },
  sessionId: string | undefined,
  visit: unknown,
): boolean {
  if (!held || held.sessionId !== sessionId) return false;
  // A stale render (the client already moved on: trustVisit's symbol) matches no chat, and neither
  // does a request made from one (`visitOf` marks it).
  if (typeof visit === "symbol" || held.visit?.startsWith(STALE_VISIT)) return false;
  // An established chat is its own scope across visits (A → B → A keeps its question); only fresh
  // chats, which share no session id, are told apart by the visit.
  if (sessionId !== undefined) return true;
  return held.visit === undefined || held.visit === visit;
}

/// The visit to record on a held folder question or retry. No client (a gallery frame) records none,
/// and the session id alone scopes it. A stale render's sentinel (a symbol: the client has already
/// moved on) records a mark no visit ever matches, so what it started never shows in another chat.
export function visitOf(visit: unknown): { visit?: string } {
  if (typeof visit === "string") return { visit };
  if (typeof visit === "symbol") return { visit: `${STALE_VISIT}${crypto.randomUUID()}` };
  return {};
}

/// A held Trust retry's key: an established chat's session id, or for a fresh chat (no id) the client
/// visit it was refused in (none: unbound). A → B → A finds A's retry again.
function retryKey(chat: string | undefined, visit: unknown): string {
  return JSON.stringify(chat !== undefined ? [chat] : [null, typeof visit === "string" ? visit : null]);
}

/// Why Send is off; an empty block only reports a trust read in flight. `shownAbove`: the
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

/// The question acpmux's last refusal for a chat (`said`) asks, when it outranks `read` (the
/// folder's trust as read, if any): acpmux's gate is the authority, so a read that shows no
/// question (an auto-trust rule) still shows the refusal's, and one for another spelling of the
/// folder asks about the folder acpmux named, which is the one its gate checks. Leo 2026-10-21: the
/// pane said only "Not sent: trust.pending", with no Trust button to clear it.
function refusedShown(
  said: { cwd: string; level: TrustLevel } | undefined,
  folder: string,
  read: ReturnType<typeof shownTrust> | undefined,
  repo: TrustRepo | undefined,
  family: string | undefined,
  canAnswer: boolean,
) {
  if (!said) return undefined;
  // The read's own question stands only when it asks what acpmux's gate asks: a pending question
  // for `trust.pending`, Don't trust's for `trust.untrusted`. A read that says the folder was
  // answered "untrusted" while the gate says pending is stale, and would hide the Trust button.
  const readAgrees = read?.ask !== undefined && (read.ask.state === "decided") === (said.level === "untrusted");
  if (readAgrees && said.cwd === folder) return undefined;
  const forced = shownTrust(
    { cwd: said.cwd, level: said.level, ...(said.cwd === folder && repo ? { repo } : {}) },
    said.cwd,
    family,
    canAnswer,
  );
  return { ...forced, trusted: false };
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
  chat: {
    sessionId?: string;
    cwd?: string;
    family?: string;
    prompts: number;
    authority?: unknown;
    visit?: unknown;
    /// Bumped to read the folder again with no other change (a New Tab page Cmd-T adopted with its screen kept:
    /// the reads it made while parked had no tab's roots, SHORTCUT FRAMES F2).
    reread?: number;
  },
  canAnswer = true,
  /// The chat's folder is on this computer: only then is its answer kept by path for the next chat.
  local = true,
  /// Shared with Composer: no trust retry may bypass an unresolved folder choice or auth refusal.
  blockSend = false,
) {
  // A connection/host identity, stable while streaming. Equal paths on another machine are not
  // the same trust scope, even when a migration preserves the chat id.
  const { sessionId, family, prompts, authority = source, visit = sessionId, reread = 0 } = chat;
  // A live getter also fences the interval between the client's route change and React's render.
  const authorityValue = typeof authority === "function" ? authority() : authority;
  const visitValue = typeof visit === "function" ? visit() : visit;
  const authorityState = useRef({ value: authorityValue, canAnswer, local, epoch: 0 });
  const priorAuthority = authorityState.current;
  if (
    priorAuthority.value !== authorityValue ||
    priorAuthority.canAnswer !== canAnswer ||
    priorAuthority.local !== local
  )
    authorityState.current = { value: authorityValue, canAnswer, local, epoch: priorAuthority.epoch + 1 };
  const authorityEpoch = authorityState.current.epoch;
  const sameAuthority = useCallback(
    () =>
      authorityState.current.epoch === authorityEpoch &&
      (typeof authority === "function" ? authority() : authority) === authorityValue,
    [authority, authorityValue, authorityEpoch],
  );
  // A New Tab has no client generation on its first render. Its first client may select the
  // created session before React paints; accept that one initial bind, while every already-bound
  // visit remains exact so an old chat cannot cross a later selection.
  const visitWasUnbound = visitValue === undefined;
  const [ask, setAsk] = useState<FolderTrustAsk>();
  const [trusted, setTrusted] = useState(false);
  const [scope, setScope] = useState<TrustScope>();
  const [justTrusted, setJustTrusted] = useState(false);
  const [revision, setRevision] = useState(0);
  const bumpRevision = useCallback(() => setRevision((value) => value + 1), []);
  const undoTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [reading, setReading] = useState(false);
  /// Bumped by `recheck` (acpmux refused a prompt the pane did not hold): read the folder again.
  const [reads, setReads] = useState(0);
  /// The folder acpmux named in a trust refusal for this chat, and the prompt to send after Trust.

  const [refusal, setRefusal] = useState<{ sessionId?: string; cwd?: string; authorityEpoch: number }>();
  /// Each chat's refused prompt, sent again after Trust there: another chat's refusal keeps its own.
  /// Each is kept until Trust has saved and no folder choice or auth refusal holds the chat.
  /// Keyed by chat and visit (`retryKey`): fresh chats share no session id, so each keeps its own.
  const resend = useRef(
    new Map<
      string,
      { again: () => void; declined?: () => void; cwds: (string | undefined)[]; family?: string; ready: boolean }
    >(),
  );
  /// The keys a chat's held retry may sit under: its visit's, then the unbound one (a New Tab's first
  /// render has no client visit yet, and its retry stays its own once the visit binds).
  const retryKeys = (chat: string | undefined, visit: unknown) =>
    chat === undefined && typeof visit === "string"
      ? [retryKey(chat, visit), retryKey(chat, undefined)]
      : [retryKey(chat, undefined)];
  const heldRetry = (chat: string | undefined, visit: unknown) => {
    for (const key of retryKeys(chat, visit)) {
      const held = resend.current.get(key);
      if (held) return { key, held };
    }
    return undefined;
  };
  /// What acpmux's last trust refusal said of each chat's folder, until an answer there: the
  /// question draws from it when the folder's read gets no answer in time (a peer's folder, read
  /// over the peer link) or disagrees with acpmux's gate. Kept per chat, so a chat switch keeps it.
  const refusedTrust = useRef(new Map<string | undefined, { cwd: string; level: TrustLevel }>());
  /// The chat whose refusal drew the question on screen, if one did: another chat in the folder
  /// does not take it (its own refusal or read answers there).
  const askFromRefusal = useRef<{ sessionId?: string } | undefined>(undefined);
  const cwd =
    chat.cwd ??
    (refusal?.authorityEpoch === authorityEpoch && refusal.sessionId === sessionId ? refusal.cwd : undefined);

  // The chat a reply belongs to; a late reply for another one is dropped.
  const current = useRef({ sessionId, cwd, canAnswer, local, authorityEpoch });
  current.current = { sessionId, cwd, canAnswer, local, authorityEpoch };
  const decidedAt = useRef<number | undefined>(undefined);
  // One answer at a time: a second click while the first saves is ignored.
  const saving = useRef(false);
  // Trust may finish after the pane unmounts (for example, while switching panes). Do not resend
  // the refused prompt or write state after that lifecycle boundary.
  const mounted = useRef(true);
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
  const keptAuthority = useRef(authorityEpoch);
  if (keptAuthority.current !== authorityEpoch) {
    keptAuthority.current = authorityEpoch;
    lastRead.current = undefined;
    refusedTrust.current.clear();
    resend.current.clear();
    answers.current.clear();
    askFromRefusal.current = undefined;
    saving.current = false;
    decidedAt.current = undefined;
    clearTimeout(undoTimer.current);
  }

  // Another chat, folder or agent: drawn in this render, so no frame shows it unread. The same
  // folder keeps its answer and is not read again (Leo 2026-10-19); another agent there takes its
  // own level from that answer. Another folder draws from its known trust, reading only when the
  // pane never read it.
  const chatKey = JSON.stringify([authorityEpoch, sessionId, cwd, family, canAnswer, local, visitValue]);
  const folderKey = JSON.stringify([authorityEpoch, cwd, canAnswer, local]);
  const owner = useRef({ key: chatKey, epoch: 0 });
  if (owner.current.key !== chatKey) owner.current = { key: chatKey, epoch: owner.current.epoch + 1 };
  const ownerEpoch = owner.current.epoch;
  const sameVisit = useCallback(
    () =>
      owner.current.epoch === ownerEpoch &&
      (visitWasUnbound || (typeof visit === "function" ? visit() : visit) === visitValue),
    [ownerEpoch, visit, visitValue, visitWasUnbound],
  );
  const [shownChat, setShownChat] = useState<{ chat: string; folder: string }>();
  if (shownChat?.chat !== chatKey) {
    const sameFolder = shownChat?.folder === folderKey;
    setShownChat({ chat: chatKey, folder: folderKey });
    setJustTrusted(false);
    const last = lastRead.current;
    const known = last && sameFolder && last.cwd === cwd ? last.trust : undefined;
    if (sameFolder && known && cwd) {
      // The folder's answer, unless acpmux refused this chat since: then its question.
      const read = shownTrust(known, cwd, family, canAnswer);
      const forced = refusedShown(refusedTrust.current.get(sessionId), cwd, read, known.repo, family, canAnswer);
      askFromRefusal.current = forced ? { sessionId } : undefined;
      const shown = forced ?? read;
      setAsk(shown.ask);
      setTrusted(shown.trusted);
      setScope(shown.scope);
    } else if (sameFolder) {
      const own = cwd
        ? refusedShown(refusedTrust.current.get(sessionId), cwd, undefined, undefined, family, canAnswer)
        : undefined;
      const fromOther = askFromRefusal.current && askFromRefusal.current.sessionId !== sessionId;
      askFromRefusal.current = own ? { sessionId } : undefined;
      if (own) {
        setAsk(own.ask);
        setTrusted(false);
      } else if (fromOther) {
        // Another chat's refusal drew the question: this one reads the folder for its own.
        setAsk(undefined);
        setReading(Boolean(cwd));
        setReads((count) => count + 1);
      } else {
        // The answer belongs to the last chat: another one starts with the folder's question or none.
        setAsk((was) => (was?.state === "decided" && was.level === "trusted" ? undefined : was));
      }
    } else {
      // The persisted path cache belongs to this page's initial local authority. Once its route
      // changes, read the new authority instead of projecting a previous host's answer by path.
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
      if (!live || !sameAuthority()) return;
      setReading(false);
      // An answer saved since this read began is newer than it: the answer stands.
      if ((answers.current.get(cwd) ?? 0) !== answered) return;
      // A folder the pane can't read is not asked about (a known answer stays); acpmux still
      // refuses its prompts, and once it has, its refusal draws the question (for the folder it
      // named, which can be another spelling of the chat's).
      const chatNow = current.current.sessionId;
      if (!trust) {
        const shown = refusedShown(
          refusedTrust.current.get(chatNow),
          cwd,
          undefined,
          undefined,
          familyNow.current,
          canAnswer,
        );
        if (shown) {
          askFromRefusal.current = { sessionId: chatNow };
          setAsk((was) => (sameAsk(was, shown.ask) ? was : shown.ask));
          setTrusted(false);
        }
        return;
      }
      const read = shownTrust(trust, cwd, familyNow.current, canAnswer);
      const forced = refusedShown(
        refusedTrust.current.get(chatNow),
        cwd,
        read,
        trust.repo,
        familyNow.current,
        canAnswer,
      );
      askFromRefusal.current = forced ? { sessionId: chatNow } : undefined;
      const shown = forced ?? read;
      if (!forced) {
        if (remembers) rememberTrust(cwd, trust);
        lastRead.current = { cwd, trust };
      }
      setAsk((was) => (sameAsk(was, shown.ask) ? was : shown.ask));
      setTrusted(shown.trusted);
      setScope(shown.scope);
    });
    return () => {
      live = false;
    };
  }, [source, cwd, reads, reread, canAnswer, remembers, sameAuthority]);

  useEffect(() => {
    if (
      ask?.state === "decided" &&
      ask.level === "trusted" &&
      decidedAt.current !== undefined &&
      prompts > decidedAt.current
    )
      setAsk(undefined);
  }, [ask, prompts]);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      clearTimeout(undoTimer.current);
    };
  }, []);

  /// Records `level` for `folder` (the chat's folder, its repository, or for Undo the folder the
  /// answer was made for): the chat's folder takes it from there.
  const save = useCallback(
    async (level: TrustLevel, folder?: string) => {
      if ((!ask && !cwd) || saving.current || !mounted.current || !sameAuthority() || !sameVisit()) return;
      bumpRevision();
      saving.current = true;
      const asked = { sessionId, cwd: ask?.cwd ?? cwd! };
      // The chat the answer was made in: the asked folder can be another spelling of its folder
      // (the one acpmux named in a refusal).
      const chatCwd = current.current.cwd;
      const refusalBeforeSave = refusedTrust.current.get(sessionId);
      const repo = ask?.repo ?? (scope?.cwd === asked.cwd ? scope.repo : undefined);
      const recorded = folder ?? asked.cwd;
      const stillHere = () =>
        mounted.current &&
        sameAuthority() &&
        sameVisit() &&
        current.current.authorityEpoch === authorityEpoch &&
        owner.current.epoch === ownerEpoch &&
        current.current.sessionId === asked.sessionId &&
        current.current.cwd === chatCwd;
      try {
        await source.set(recorded, level);
        // Fence every effect, including cache/refusal mutations and forced composer replay.
        // The same UUID and cwd can now belong to another machine or a newer connection.
        if (!mounted.current || !sameAuthority()) return;
        // A newer refusal for this chat may arrive while the older Trust save is in flight. It
        // owns the question and its replay even on the same render/visit; never replace it with
        // the older save's folder or consume its callback.
        if (refusedTrust.current.get(asked.sessionId) !== refusalBeforeSave) return;
        if (refusedTrust.current.get(asked.sessionId) === refusalBeforeSave)
          refusedTrust.current.delete(asked.sessionId);
        if (askFromRefusal.current?.sessionId === asked.sessionId) askFromRefusal.current = undefined;
        // In an alternate-cwd refusal, `asked.cwd` is the folder acpmux named while `chatCwd`
        // is the folder whose read is still in flight. Invalidate both generations so that a
        // late answer from the chat's spelling cannot put the question back after Trust.
        const answerFolders = [asked.cwd, recorded, chatCwd].filter((value): value is string => Boolean(value));
        for (const key of new Set(answerFolders)) {
          answers.current.set(key, (answers.current.get(key) ?? 0) + 1);
        }
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
        if (!stillHere()) {
          // The user may have switched to another chat in the same folder while saving. Its
          // old refresh may already have drawn the pre-answer question; reconcile the folder
          // answer there too, while preserving that chat's own later refusal. Never resend A in B.
          const now = current.current;
          if (!mounted.current || !chatCwd || now.cwd !== chatCwd || now.canAnswer !== canAnswer || now.local !== local)
            return;
          // Equal paths on different peers are not the same folder. Only a local answer can be
          // projected by path; a remote/peer chat must ask its current source again instead of
          // inheriting another host's trust decision.
          if (!answer || !remembers) {
            setReading(Boolean(chatCwd));
            setReads((count) => count + 1);
            return;
          }
          const read = shownTrust({ ...answer, cwd: chatCwd }, chatCwd, familyNow.current, canAnswer);
          const forced = refusedShown(
            refusedTrust.current.get(now.sessionId),
            chatCwd,
            read,
            answer.repo,
            familyNow.current,
            canAnswer,
          );
          const shown = forced ?? read;
          askFromRefusal.current = forced ? { sessionId: now.sessionId } : undefined;
          setReading(false);
          setAsk(shown.ask);
          setTrusted(shown.trusted);
          setScope(shown.scope);
          return;
        }
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
        const found = heldRetry(asked.sessionId, visitValue);
        if (level === "trusted") {
          if (found) found.held.ready = true;
        } else if (found) {
          resend.current.delete(found.key);
          found.held.declined?.();
        }
      } catch {
        if (stillHere()) setAsk({ cwd: asked.cwd, state: "failed" });
      } finally {
        if (sameAuthority()) saving.current = false;
      }
    },
    [
      ask,
      cwd,
      scope,
      source,
      sessionId,
      prompts,
      remembers,
      canAnswer,
      local,
      authorityEpoch,
      ownerEpoch,
      bumpRevision,
      sameAuthority,
      sameVisit,
      visitValue,
    ],
  );

  // Both Composer.send and failed-row retries pass through this one gate. Retain the callback
  // (and its prompt/attachments/gesture) while the folder answer saves; never replay in another chat.
  useEffect(() => {
    // A retry Trust already released waits only on the folder choice: leaving its chat drops it.
    // One still waiting for Trust stays with its chat (sent after Trust there, as before).
    // Fresh chats share no session id: the visit a retry was refused in tells them apart.
    const mine = new Set(retryKeys(sessionId, visitValue));
    for (const [key, waiting] of resend.current) if (!mine.has(key) && waiting.ready) resend.current.delete(key);
    const found = heldRetry(sessionId, visitValue);
    if (!found) return;
    const { key, held } = found;
    if (!held.cwds.includes(cwd) || held.family !== family) {
      resend.current.delete(key);
      return;
    }
    if (!held.ready || !trusted || blockSend || !cwd || !mounted.current) return;
    // The client may already have selected another chat or connection while React still shows
    // this one: its render-time values pass, the live ones do not. Keep the callback; the next
    // render, for the chat now selected, drops this chat's released retry.
    if (!sameAuthority() || !sameVisit()) return;
    resend.current.delete(key);
    try {
      held.again();
    } catch {
      // A failed retry stays in its row/draft and keeps the question recoverable, as save did.
      setAsk({ cwd, state: "failed" });
    }
  }, [ask, trusted, blockSend, sessionId, cwd, family, sameAuthority, sameVisit, visitValue]);

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
    revision,
    /// The trust question or Don't trust holds the chat's other asks (permission, secret, tool
    /// cards): one question at a time. A read in flight asks nothing, so it holds nothing; the asks
    /// keep their place while it reads (a chat switch). The daemon authorizes any prompt sent meanwhile.
    holdsAsks: Boolean(blocked?.reason),
    trusted,
    /// Where the folder's answer lives (its repository, a parent folder), for the trusted grant.
    scope,
    justTrusted,
    blocked,
    /// Explicit Retry shares the same hard stop as Trust's automatic retry. While blocked,
    /// leave the failed rows and any held trust callback intact. A manual send that can run
    /// supersedes that callback, so the next effect cannot send the same prompt a second time.
    retry: <T>(again: () => Promise<T>): Promise<T | undefined> => {
      if (blockSend) return Promise.resolve(undefined);
      for (const key of retryKeys(sessionId, visitValue)) resend.current.delete(key);
      return again();
    },
    /// Cancel leaves the draft or failed row in place for a later explicit send/retry.
    cancelResend: useCallback(() => {
      for (const key of retryKeys(sessionId, visitValue)) resend.current.delete(key);
    }, [sessionId, visitValue]),
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
        if (!mounted.current || !sameAuthority() || !sameVisit()) return false;

        const said = trustRefusal(error);
        if (!said) return false;
        bumpRevision();
        const named = said.cwd;
        if (named) setRefusal({ sessionId, cwd: named, authorityEpoch });
        const refusedFolder = named ?? cwd;
        if (refusedFolder)
          refusedTrust.current.set(sessionId, {
            cwd: refusedFolder,
            level: said.reason === "trust.untrusted" ? "untrusted" : "unknown",
          });
        else refusedTrust.current.delete(sessionId);
        // acpmux says the folder is not trusted now: its record is stale, and Send waits for the read.
        for (const folder of [named, cwd]) if (typeof folder === "string" && folder) rememberTrust(folder, undefined);
        lastRead.current = undefined;
        setTrusted(false);
        setReading(true);
        // A refusal without its own re-run (a prompt the client routed first) keeps the one set.
        if (again)
          resend.current.set(retryKey(sessionId, visitValue), {
            again,
            declined,
            cwds: [cwd, refusedFolder],
            family,
            ready: false,
          });
        else {
          const found = heldRetry(sessionId, visitValue);
          if (found) found.held.ready = false;
        }

        setReads((count) => count + 1);
        return true;
      },
      [sessionId, cwd, family, authorityEpoch, bumpRevision, sameAuthority, sameVisit, visitValue],
    ),
  };
}
