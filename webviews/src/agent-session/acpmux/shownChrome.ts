// What a chat's page already drew of its chrome stays drawn until the chat's attach answers. Leo,
// 2026-11-22: "the bypass permissions appears then disappears after it loaded in."
//
// The page's first frames come from what it kept (the reload copy, the host's kept tail), which holds the
// chat's whole summary: its permission modes, its model, its options. The client that then connects
// publishes the chat before its attach answered (the open's hold running out on a slow daemon, a session
// row changing meanwhile), from the listed row alone, which names no `modes` and no `configOptions`. Each
// of those frames replaced the whole snapshot, so the mode chip went and came back with the attach.
// Here the frames before the attach keep what the page showed of the same chat wherever they name
// nothing; the attach's frame, and every one after it, is drawn as the client gives it.
import type { AcpmuxSnapshot } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// The summary's fields the composer's chips and the header are drawn from, which a listed row may
/// lack. Never the live ones (status, queue, usage, retry): a stale one of those would be a claim.
const CHROME: readonly (keyof Summary)[] = [
  "modes",
  "configOptions",
  "model",
  "effort",
  "harness",
  "family",
  "cwd",
  "branch",
  "worktree",
  "title",
  "name",
  "promptCapabilities",
  "tools",
  "mcpServers",
];

/// The client's `connection` on the frame its attach landed (direct.ts `emit("attached")`), and the
/// ones that say the chat will not be read.
const ATTACHED = "attached";
const ENDED = new Set(["failed", "disconnected"]);

export type ShownChrome = {
  /// `next` as the page draws it: itself, or with the chrome `previous` showed of the same chat
  /// where `next` names none, while that chat's attach has not answered on this page.
  keep(previous: AcpmuxSnapshot | undefined, next: AcpmuxSnapshot): AcpmuxSnapshot;
  /// The page's client went: the next one attaches the chat again, and its frames before that keep
  /// what the page shows now.
  clientLost(): void;
};

export function shownChrome(): ShownChrome {
  // Chats whose attach answered on this page: drawn as the client gives them from then on.
  const attached = new Set<string>();
  // The last frame made, so the same two summaries give the same object (the pane compares the
  // summary by identity: direct.ts `publishedSummary`).
  let last: { from: Summary; onto: Summary | undefined; value: Summary } | undefined;
  // The permission modes each chat last named, and the harness that named them. A read chat's detail
  // can come without them (acpmux drops `modes` first from a reply too big to send: hub/paging.rs),
  // and the chip then went for good; a chat's modes are its own until it names others, so the frame
  // keeps the ones it named while the chat runs the same harness.
  const named = new Map<string, { harness: Summary["harness"]; modes: NonNullable<Summary["modes"]> }>();
  const withModes = new WeakMap<Summary, Summary>();
  const note = (summary: Summary | undefined) => {
    if (summary?.sessionId && summary.modes)
      named.set(summary.sessionId, { harness: summary.harness, modes: summary.modes });
  };
  const read = (sessionId: string, next: AcpmuxSnapshot): AcpmuxSnapshot => {
    const summary = next.summary;
    if (!summary || summary.sessionId !== sessionId) return next;
    if (summary.modes) {
      note(summary);
      return next;
    }
    const was = named.get(sessionId);
    if (!was || was.harness !== summary.harness) return next;
    let value = withModes.get(summary);
    if (!value || value.modes !== was.modes) {
      value = { ...summary, modes: was.modes };
      withModes.set(summary, value);
    }
    return { ...next, summary: value };
  };
  return {
    clientLost() {
      attached.clear();
    },
    keep(previous, next) {
      const sessionId = next.sessionId ?? next.summary?.sessionId;
      if (!sessionId) return next;
      if (!named.has(sessionId) && previous?.summary?.sessionId === sessionId) note(previous.summary);
      if (ENDED.has(next.connection)) {
        attached.add(sessionId);
        return next;
      }
      if (next.connection === ATTACHED) {
        attached.add(sessionId);
        return read(sessionId, next);
      }
      if (attached.has(sessionId)) return read(sessionId, next);
      const shown = previous?.summary;
      if (!shown || shown.sessionId !== sessionId) return next;
      const onto = next.summary;
      if (onto && onto.sessionId !== sessionId) return next;
      const catalog = next.catalog.length === 0 && previous.catalog.length > 0 ? previous.catalog : next.catalog;
      let summary: Summary | undefined = onto;
      // The frame drawn last is what shows now: the client's same summary on it draws the same one.
      if (last && last.onto === onto && (last.from === shown || last.value === shown)) summary = last.value;
      else if (shown !== onto) {
        const missing = CHROME.filter((key) => shown[key] !== undefined && onto?.[key] === undefined);
        if (missing.length > 0) {
          const kept: Record<string, unknown> = { ...(onto ?? { sessionId }) };
          for (const key of missing) kept[key] = shown[key];
          summary = kept as Summary;
          last = { from: shown, onto, value: summary };
        }
      }
      if (summary === onto && catalog === next.catalog) return next;
      return { ...next, summary, catalog };
    },
  };
}
