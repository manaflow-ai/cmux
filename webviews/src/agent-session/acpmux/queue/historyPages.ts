// The wiring of History's Waiting on you and Costs tabs (newtab/HistoryScreen.tsx) in the pane
// (App.tsx): reads through the pane's own acpmux connection (direct.ts), answers through Needs
// you's path (needsYou/useNeedsYou.ts `answerAnotherChat`), and a chat shown the way History's own
// rows and the New Tab page's open one: in this tab, in place of the page (App.tsx `selectSession`,
// `chat.select`). Needs you's `chat.asks.open` opens nothing from a New Tab page.
import { copyTextResult } from "../conversation/clipboard";
import type { WatchedAsk } from "../needsYou/model";
import { answerAnotherChat } from "../needsYou/useNeedsYou";
import type { LedgerScreen } from "../ledger/LedgerScreen";
import type { TeamAuditScreen } from "../teamAudit/TeamAuditScreen";
import type { QueueScreen } from "./QueueScreen";
import { auditEntries, needsYouItem, QUEUE_LIMIT, verdictParams, type QueueItem } from "./queueModel";
import type { AcpmuxSessionEntry } from "../sessionList";
import type { ComponentProps } from "react";

type CallNative = <T>(method: string, params?: Record<string, unknown>) => Promise<T>;

/// The pane's connection calls these pages use (AcpmuxDirectClient).
export type HistoryPagesClient = {
  ledger(params: Record<string, unknown>): Promise<unknown>;
  teamAudit(params: Record<string, unknown>): Promise<unknown>;
  reviewQueue(params?: Record<string, unknown>): Promise<unknown>;
  reviewVerdict(params: Record<string, unknown>): Promise<unknown>;
  audit(params?: Record<string, unknown>): Promise<unknown>;
};

/// At most this many audit pages are read for one export.
export const AUDIT_PAGES = 50;
const AUDIT_PAGE = 1000;

/// What the queue's read depends on, as one key the pane's snapshot gives for free: this Mac's
/// pending asks (by permission id), and for every listed chat, this Mac's and other machines',
/// what it waits on (its ask count, `waitingOn`, its status dot), its status (acpmux lists a chat's
/// pull request only while the chat is idle), its title and name (a row names its chat), and every
/// pull request field a row shows: number,
/// title, state, review ready, checks and each URL. It changes when an ask or a pull request the
/// queue lists comes, goes or moves, on any machine the snapshot lists, so the tab reads again then
/// and never on a timer. One pass over the snapshot; a chat with none of these adds nothing.
export function queueKey(asks: readonly WatchedAsk[], sessions: readonly AcpmuxSessionEntry[] = []): string {
  const parts = asks.map((ask) => ask.permission.permissionId);
  for (const session of sessions) {
    const pending = session.pendingPermissions ?? 0;
    const input = session.indicator === "input";
    const waiting = session.waitingOn?.on ?? "";
    const pr = session.pullRequest;
    const urls = session.pullRequestUrls ?? [];
    if (!pending && !input && !waiting && session.status !== "waiting" && !pr && urls.length === 0) continue;
    const prKey = pr ? JSON.stringify([pr.number, pr.title, pr.state, pr.reviewReady ?? false, pr.checks ?? ""]) : "";
    parts.push(
      JSON.stringify([
        session.sessionId,
        pending,
        input,
        waiting,
        session.status ?? "",
        session.title ?? "",
        session.name ?? "",
        prKey,
        urls,
      ]),
    );
  }
  return parts.join(",");
}

/// The listed chat a queue item names: this Mac's by its id, another machine's by that machine's
/// name and the id its own daemon gave it (the snapshot lists it as `HOST/ID` or with `peer`).
export function itemSession(item: QueueItem, sessions: readonly AcpmuxSessionEntry[]): string | undefined {
  if (!item.sessionId) return undefined;
  if (!item.host) return item.sessionId;
  const qualified = `${item.host}/${item.sessionId}`;
  const listed = sessions.find(
    (session) =>
      session.sessionId === qualified ||
      ((session.peer === item.host || session.host === item.host) && session.sessionId === item.sessionId),
  );
  return listed?.sessionId ?? qualified;
}

export function historyPages({
  client,
  callNative,
  selectSession,
  asks,
  sessions = [],
  copy = copyTextResult,
}: {
  client: () => HistoryPagesClient | undefined;
  callNative: CallNative;
  /// Shows chat `sessionId` of this Mac's acpmux in this tab (App.tsx `selectSession`).
  selectSession: (sessionId: string) => void;
  asks: readonly WatchedAsk[];
  /// The chats the pane lists, this Mac's and other machines' (the snapshot's `sessions`).
  sessions?: readonly AcpmuxSessionEntry[];
  /// Copies text, false when neither clipboard path took it (conversation/clipboard.ts).
  copy?: (text: string) => Promise<boolean>;
}): {
  queue: ComponentProps<typeof QueueScreen>;
  ledger: ComponentProps<typeof LedgerScreen>;
  team: ComponentProps<typeof TeamAuditScreen>;
} {
  const connected = () => {
    const current = client();
    // l10n-allow: a rejection reason for the wire log only; the row shows its own localized failure text
    if (!current) throw Object.assign(new Error("not connected"), { code: "native.not_connected" });
    return current;
  };
  const open = (item: QueueItem) => {
    // Another machine's chat opens as the sidebar and the home's lists open it: its listed row.
    const session = itemSession(item, sessions);
    if (session) selectSession(session);
  };
  return {
    queue: {
      refreshKey: queueKey(asks, sessions),
      load: async () => connected().reviewQueue({ limit: QUEUE_LIMIT }),
      answer: (item, choice) =>
        answerAnotherChat(callNative, needsYouItem(item), choice, {
          peer: Boolean(item.host),
          open: () => open(item),
        }),
      verdict: async (item, verdict, comment) => {
        // Another machine's pull request is reviewed there (its row offers no verdict): refused, so
        // the row stays rather than hiding while acpmux still lists it.
        // l10n-allow: a rejection reason for the wire log only; the row shows its own localized failure text
        if (item.host) throw new Error("answered on its machine");
        const params = verdictParams(item, verdict, comment);
        if (!params) throw new Error("unanswerable");
        const reply = await connected().reviewVerdict(params);
        // An acpmux that predates the comment (or a chat that did not take it) records the verdict
        // without the words reaching the chat: they go to the clipboard and the chat opens, so
        // the person pastes what should change rather than writing it again. When the clipboard
        // refuses too, the page stays: its notice holds the only copy of the words.
        const words = typeof params.comment === "string" ? params.comment : undefined;
        if (words && (reply as { commentDelivered?: unknown } | null)?.commentDelivered !== true) {
          const copied = await copy(words);
          if (copied) open(item);
          return { ...(reply as object | null), commentCopied: copied };
        }
        return reply;
      },
      open,
      exportAudit: async () => {
        const entries = await auditEntries(
          (params) => connected().audit({ limit: AUDIT_PAGE, ...params }),
          AUDIT_PAGES,
        );
        // copyText resolves even when both clipboard paths fail: say so instead of "copied".
        // l10n-allow: a rejection reason for the wire log only; the row shows its own localized failure text
        if (!(await copy(`${JSON.stringify(entries, null, 2)}\n`))) throw new Error("clipboard refused");
        return entries.length;
      },
      openReview: () => void callNative("action.run", { id: "agentReview.show" }).catch(() => undefined),
    },
    ledger: {
      load: async (params) => connected().ledger(params),
      openSession: selectSession,
      copy,
      // The host's save panel, as a side panel document's Save (`pane.saveFile`); a host that
      // cannot save it (one that predates the kind, or a failed write) copies it instead.
      save: async (text, suggestedName, kind) => {
        try {
          const saved = await callNative<boolean>("pane.saveFile", { text, suggestedName, kind });
          return saved === true ? "saved" : "cancelled";
        } catch {
          // l10n-allow: a rejection reason for the wire log only; the page shows its own localized failure text
          if (!(await copy(text))) throw new Error("clipboard refused");
          return "copied";
        }
      },
    },
    // History shows it only while the `team-audit` experiment is on (newtab/HistoryScreen.tsx).
    team: { load: async (params) => connected().teamAudit(params) },
  };
}
