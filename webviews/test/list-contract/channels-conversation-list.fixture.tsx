// l10n-allow-file: fixture conversations, not shipped UI.
// Home's channel and direct-message list (Channels page, left column): one row per conversation,
// every conversation the person has. The page's store hands a new Map on each change.
import { useMemo } from "react";
import { ConversationList } from "../../src/pages/home-channels/ConversationList";
import table from "../../src/pages/home-channels/generated/strings.json";
import type { HomeConversation } from "../../src/pages/home-channels/types";
import { createStrings } from "../../src/pages/shared/i18n";
import "../../src/pages/shared/pageBase.css";
import "../../src/ui/ui.css";
import "../../src/pages/home-channels/styles.css";
import "../../src/pages/home-channels/ledger.css";
import { listFixture } from "./listFixture";

const ME = "me";
const START = Date.UTC(2026, 10, 18, 9);
const strings = createStrings(table, ["en"]);
const actions = { canPin: true, onPin() {}, onMarkUnread() {}, onMarkRead() {}, onCopyLink() {} };
const none = () => {};

export default listFixture<HomeConversation>({
  source: "pages/home-channels/ConversationList.tsx#ConversationList",
  rows: ".lg-list-group > li",
  scroller: ".lg-list-rows",
  item: (index) => ({
    id: `c${index}`,
    owner: "local",
    title: index % 3 ? "" : `channel-${index}`,
    kind: index % 3 ? "direct" : "group",
    participants: [
      { id: ME, kind: "human", name: "Me", chief: false },
      { id: `p${index}`, kind: "human", name: `Person ${index}`, chief: false },
    ],
    lastSeq: 1,
    rev: 1,
    // Newest first, in index order (listOrder sorts by activity).
    updatedAt: START - index * 60_000,
    lastAt: START - index * 60_000,
    unread: index % 7 === 0 ? 2 : 0,
    mentions: 0,
    muted: false,
    pinned: false,
    lastText: `The last message in conversation ${index}`,
    lastAuthor: `p${index}`,
  }),
  // A new message's preview, at the same time so the row keeps its place.
  change: (item) => ({ ...item, rev: item.rev + 1, lastText: `${item.lastText} (edited)` }),
  render: function Render({ items, selected, onSelect }) {
    const conversations = useMemo(() => new Map(items.map((item) => [item.id, item])), [items]);
    const ids = useMemo(() => new Map(items.map((item, index) => [item.id, index])), [items]);
    return (
      <ConversationList
        conversations={conversations}
        channels={new Set()}
        people={new Map()}
        activity={new Map()}
        me={ME}
        selected={selected === undefined ? undefined : items[selected]?.id}
        strings={strings}
        onSelect={(id) => onSelect(ids.get(id) ?? 0)}
        onOpenPalette={none}
        actions={actions}
      />
    );
  },
});
