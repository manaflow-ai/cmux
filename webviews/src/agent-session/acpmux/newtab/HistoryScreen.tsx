// Agent history (cx-zlnl, Leo 2026-10-10): the page the sidebar's History dot opens. Every coding
// agent chat on this device, newest first, like a browser's history page. It is the New Tab
// page's All chats list (cx-n0i9), not a copy: the same paged chat index (`chats.page`) and the
// same Open Chat path. Here its rows also select (Cmd/Ctrl-click, Shift-click), and Enter or the
// row menu's Bring into Active Sessions opens each picked chat in the current space.
//
// Two more tabs sit beside it where the pane can read them: Waiting on you (queue/QueueScreen.tsx,
// every ask across agents and machines) and Costs (ledger/LedgerScreen.tsx, what agents spent).
// They live here because this page is one the app already opens; they need no host of their own.
import type { ComponentProps } from "react";
import { useState } from "react";
import { Tabs, TabsList, TabsTrigger } from "../../../ui/Tabs";
import { useT } from "../i18n";
import { LedgerScreen } from "../ledger/LedgerScreen";
import { QueueScreen } from "../queue/QueueScreen";
import { createQueueCache } from "../queue/useQueue";
import { createLedgerCache } from "../ledger/LedgerScreen";
import { AllChatsList } from "./AllChatsList";
import { type LoadChatsPage } from "./allChatsListModel";
import { useNoEntryMotion } from "./noEntryMotion";
import { useNt } from "./strings";

export type HistoryTab = "history" | "queue" | "ledger";

export function HistoryScreen({
  load,
  onOpen,
  onOpenInTerminal,
  onViewOnly,
  now,
  queue,
  ledger,
  initialTab = "history",
}: {
  load: LoadChatsPage;
  onOpen(key: string): unknown;
  onOpenInTerminal?(key: string): void;
  onViewOnly?(key: string): void;
  now?: number;
  /// Waiting on you's reads and answers; no tab without them.
  queue?: ComponentProps<typeof QueueScreen>;
  /// Costs' read; no tab without it.
  ledger?: ComponentProps<typeof LedgerScreen>;
  initialTab?: HistoryTab;
}) {
  const nt = useNt();
  const t = useT();
  // A New Tab page too: what it shows or opens appears at once (noEntryMotion.ts).
  useNoEntryMotion();
  const [tab, setTab] = useState<HistoryTab>(initialTab);
  // What Waiting on you and Costs last showed, kept while another tab shows: a return paints it
  // at once, and Waiting on you reads again only when what it lists changed meanwhile.
  const [queueCache] = useState(createQueueCache);
  const [ledgerCache] = useState(createLedgerCache);
  const tabbed = Boolean(queue || ledger);
  const shown: HistoryTab = (tab === "queue" && !queue) || (tab === "ledger" && !ledger) ? "history" : tab;
  return (
    <div className="nt-history" data-tab={shown}>
      {/* The page's title stays on every tab, with the tabs under it, so switching moves nothing above. */}
      <h1 className="nt-history-title">{nt("history")}</h1>
      {tabbed && (
        <Tabs
          variant="pill"
          value={shown}
          onValueChange={(value) => setTab(value as HistoryTab)}
          className="nt-history-tabs"
        >
          <TabsList aria-label={nt("history")}>
            <TabsTrigger value="history">{nt("history")}</TabsTrigger>
            {queue && <TabsTrigger value="queue">{t("waiting.title")}</TabsTrigger>}
            {ledger && <TabsTrigger value="ledger">{t("ledger.title")}</TabsTrigger>}
          </TabsList>
        </Tabs>
      )}
      {shown === "queue" && queue ? (
        <QueueScreen {...queue} cache={queueCache} {...(now !== undefined ? { now } : {})} />
      ) : shown === "ledger" && ledger ? (
        <LedgerScreen {...ledger} cache={ledgerCache} {...(now !== undefined ? { now } : {})} />
      ) : (
        <AllChatsList
          load={load}
          onOpen={onOpen}
          // Each chat opens through Open Chat, as a click does: in a new workspace of this space.
          onBring={(keys) => Promise.all(keys.map((key) => Promise.resolve(onOpen(key)))).then(() => undefined)}
          {...(onOpenInTerminal ? { onOpenInTerminal } : {})}
          {...(onViewOnly ? { onViewOnly } : {})}
          {...(now !== undefined ? { now } : {})}
        />
      )}
    </div>
  );
}
