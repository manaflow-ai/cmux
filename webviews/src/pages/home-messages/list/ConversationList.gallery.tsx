// l10n-allow-file: gallery fixtures, not shipped UI.
// The Messages page's conversation list in its states and its three looks. The pick (recorded in
// design/home.md): `messages`, the theme's neutral selection slab with hairlines between rows, as
// the native list draws it today.
import { useMemo, useState } from "react";
import { GALLERY_NOW } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import { createStrings } from "../../shared/i18n";
import table from "../generated/strings.json";
import { ConversationList, type ListLook } from "./ConversationList";
import { ME, sampleConversations } from "./fixtures";
import { listModel } from "./model";

type Props = {
  width: number;
  count: number;
  look?: ListLook;
  selected?: string;
  query?: string;
  unreadOnly?: boolean;
  lights?: boolean;
  requests?: number;
  note?: string;
  draft?: boolean;
};

function ListStage({
  width,
  count,
  look,
  selected: first,
  query: initialQuery = "",
  unreadOnly: initialUnread = false,
  lights,
  requests,
  note,
  draft,
}: Props) {
  const [strings] = useState(() => createStrings(table));
  const [conversations, setConversations] = useState(() => sampleConversations(count, GALLERY_NOW));
  const [selected, setSelected] = useState(first);
  const [query, setQuery] = useState(initialQuery);
  const [unreadOnly, setUnreadOnly] = useState(initialUnread);
  const words = useMemo(
    () => ({
      untitled: strings.t("home.list.untitled"),
      yesterday: strings.t("home.sidebar.yesterday"),
      channel: strings.t("home.list.channel"),
      mentioned: strings.t("home.list.mentioned"),
      unread: (n: number) => strings.format("home.list.unread", String(n)),
    }),
    [strings],
  );
  const model = useMemo(
    () =>
      listModel(conversations, { me: ME.id, query, unreadOnly, now: GALLERY_NOW, language: strings.language, words }),
    [conversations, query, unreadOnly, strings, words],
  );
  const patch = (
    id: string,
    change: Partial<{ pinned: boolean; pinPosition: number; markedUnread: boolean; unread: number }>,
  ) =>
    setConversations((old) => {
      const current = old.get(id);
      return current ? new Map(old).set(id, { ...current, ...change }) : old;
    });
  return (
    <div style={{ width, height: "100%", display: "flex" }}>
      <ConversationList
        model={model}
        width={width}
        {...(selected ? { selected } : {})}
        query={query}
        onQuery={setQuery}
        unreadOnly={unreadOnly}
        onUnreadOnly={setUnreadOnly}
        strings={strings}
        windowControls={lights ? { x: 12, y: 14, width: 54, height: 16 } : null}
        canPin
        onSelect={setSelected}
        onOpen={setSelected}
        onSetPinned={(id, pinned) => patch(id, { pinned, pinPosition: Date.now() })}
        onArrangePinned={(order) => order.forEach((id, index) => patch(id, { pinned: true, pinPosition: index + 1 }))}
        onMarkRead={(id) => patch(id, { unread: 0, markedUnread: false })}
        onMarkUnread={(id) => patch(id, { markedUnread: true })}
        onDelete={() => {}}
        hostMenu={async () => [
          { id: "colors", title: "Chat Colors…", action: "home.chatColors" },
          { id: "mute", title: "Hide Alerts", action: "home.muteConversation" },
        ]}
        {...(draft ? { draftTitle: "New Message", onCloseDraft: () => {} } : {})}
        {...(note ? { note } : {})}
        {...(requests ? { requests } : {})}
        {...(look ? { look } : {})}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "home.messages-list",
  title: "Messages list",
  area: "Home and Chief",
  height: 720,
  widths: { narrow: 260, normal: 320, wide: 420 },
  covers: [
    "pages/home-messages/list/ConversationList.tsx#ConversationList",
    "pages/home-messages/list/ListItems.tsx",
    "page:cmux.home-messages",
  ],
  load: async () => ListStage,
  styles: () => Promise.all([import("../../shared/pageBase.css"), import("./list.css")]),
  variants: {
    messages: {
      note: "The pick: a neutral selection slab and hairlines between rows, as the native list.",
      props: { width: 320, count: 24, look: "messages", selected: "c-design" },
    },
    accent: {
      note: "The selected row a filled accent block, as Messages draws it.",
      props: { width: 320, count: 24, look: "accent", selected: "c-design" },
    },
    quiet: {
      note: "No hairlines; the selection a ring.",
      props: { width: 320, count: 24, look: "quiet", selected: "c-design" },
    },
    "unread-filter": {
      note: "The Unread filter on: its chip under the search row, unread rows only, no grid.",
      props: { width: 320, count: 24, unreadOnly: true },
    },
    "no-results": { note: "A search with no match: No Results.", props: { width: 320, count: 24, query: "zzz" } },
    search: {
      note: "A search lists matches as rows, pinned ones first.",
      props: { width: 320, count: 24, query: "Ta" },
    },
    "avatars-only": {
      note: "Below 180 pt: one column of avatars, the search a circle beside the filter.",
      props: { width: 120, count: 24, selected: "c-taylor" },
    },
    "under-traffic-lights": {
      note: "The window's lights over the header: the filter on their line, search under them.",
      props: { width: 320, count: 24, lights: true },
    },
    "requests-and-note": {
      note: "Message Requests and the Cloud note under the list, and the New Message draft row.",
      props: {
        width: 320,
        count: 6,
        requests: 2,
        note: "Cloud conversations are not available right now.",
        draft: true,
      },
    },
    "ten-thousand": {
      note: "10,000 conversations: only the rows in view are in the DOM.",
      props: { width: 320, count: 10_000 },
    },
  },
});
