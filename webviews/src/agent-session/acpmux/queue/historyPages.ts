// The wiring of History's Waiting on you and Costs tabs (newtab/HistoryScreen.tsx) in the pane
// (App.tsx): reads through the pane's own acpmux connection (direct.ts), answers through Needs
// you's path (needsYou/useNeedsYou.ts `answerAnotherChat`), and a chat shown the way History's own
// rows and the New Tab page's open one: in this tab, in place of the page (App.tsx `selectSession`,
// `chat.select`). Needs you's `chat.asks.open` opens nothing from a New Tab page.
import { copyText } from "../conversation/clipboard";
import type { WatchedAsk } from "../needsYou/model";
import { answerAnotherChat } from "../needsYou/useNeedsYou";
import type { LedgerScreen } from "../ledger/LedgerScreen";
import type { QueueScreen } from "./QueueScreen";
import { auditEntries, needsYouItem, QUEUE_LIMIT, verdictParams, type QueueItem } from "./queueModel";
import type { ComponentProps } from "react";

type CallNative = <T>(method: string, params?: Record<string, unknown>) => Promise<T>;

/// The pane's connection calls these pages use (AcpmuxDirectClient).
export type HistoryPagesClient = {
  ledger(params: Record<string, unknown>): Promise<unknown>;
  reviewQueue(params?: Record<string, unknown>): Promise<unknown>;
  reviewVerdict(params: Record<string, unknown>): Promise<unknown>;
  audit(params?: Record<string, unknown>): Promise<unknown>;
};

/// At most this many audit pages are read for one export.
export const AUDIT_PAGES = 50;
const AUDIT_PAGE = 1000;

/// The asks the pane watches as one key: it changes exactly when an ask comes or goes.
export const asksKey = (asks: readonly WatchedAsk[]) => asks.map((ask) => ask.permission.permissionId).join(",");

export function historyPages({
  client,
  callNative,
  selectSession,
  asks,
}: {
  client: () => HistoryPagesClient | undefined;
  callNative: CallNative;
  /// Shows chat `sessionId` of this Mac's acpmux in this tab (App.tsx `selectSession`).
  selectSession: (sessionId: string) => void;
  asks: readonly WatchedAsk[];
}): { queue: ComponentProps<typeof QueueScreen>; ledger: ComponentProps<typeof LedgerScreen> } {
  const connected = () => {
    const current = client();
    if (!current) throw Object.assign(new Error("not connected"), { code: "native.not_connected" });
    return current;
  };
  const open = (item: QueueItem) => {
    // Another machine's chat is answered there; this pane has no local chat to show for it.
    if (item.host || !item.sessionId) return;
    selectSession(item.sessionId);
  };
  return {
    queue: {
      refreshKey: asksKey(asks),
      load: async () => connected().reviewQueue({ limit: QUEUE_LIMIT }),
      answer: (item, choice) =>
        answerAnotherChat(callNative, needsYouItem(item), choice, {
          peer: Boolean(item.host),
          open: () => open(item),
        }),
      verdict: async (item, verdict, comment) => {
        // Another machine's pull request is reviewed there (its row offers no verdict): refused, so
        // the row stays rather than hiding while acpmux still lists it.
        if (item.host) throw new Error("answered on its machine");
        const params = verdictParams(item, verdict, comment);
        if (!params) throw new Error("unanswerable");
        return connected().reviewVerdict(params);
      },
      open,
      exportAudit: async () => {
        const entries = await auditEntries(
          (params) => connected().audit({ limit: AUDIT_PAGE, ...params }),
          AUDIT_PAGES,
        );
        await copyText(`${JSON.stringify(entries, null, 2)}\n`);
        return entries.length;
      },
      openReview: () => void callNative("action.run", { id: "agentReview.show" }).catch(() => undefined),
    },
    ledger: {
      load: async (params) => connected().ledger(params),
      openSession: selectSession,
    },
  };
}
