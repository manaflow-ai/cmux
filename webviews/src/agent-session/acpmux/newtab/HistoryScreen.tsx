// Agent history (cx-zlnl, Leo 2026-10-10): the page the sidebar's History dot opens. Every coding
// agent chat on this device, newest first, like a browser's history page. It is the New Tab
// page's All chats list (cx-n0i9), not a copy: the same paged chat index (`chats.page`) and the
// same Open Chat path. Here its rows also select (Cmd/Ctrl-click, Shift-click), and Enter or the
// row menu's Bring into Active Sessions opens each picked chat in the current space.
import { AllChatsList, type LoadChatsPage } from "./AllChatsList";
import { useNt } from "./strings";

export function HistoryScreen({
  load,
  onOpen,
  onOpenInTerminal,
  now,
}: {
  load: LoadChatsPage;
  onOpen(key: string): void;
  onOpenInTerminal?(key: string): void;
  now?: number;
}) {
  const nt = useNt();
  return (
    <div className="nt-history">
      <h1 className="nt-history-title">{nt("history")}</h1>
      <AllChatsList
        load={load}
        onOpen={onOpen}
        // Each chat opens through Open Chat, as a click does: in a new workspace of this space.
        onBring={(keys) => keys.forEach(onOpen)}
        {...(onOpenInTerminal ? { onOpenInTerminal } : {})}
        {...(now !== undefined ? { now } : {})}
      />
    </div>
  );
}
