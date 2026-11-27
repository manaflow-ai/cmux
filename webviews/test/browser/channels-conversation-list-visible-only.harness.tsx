// l10n-allow-file: bench fixture conversations, not shipped UI.
// The real Channels conversation list over N conversations (`#n=10000`), for
// bench/channels-conversation-list-visible-only.bench.ts. It holds the list as the page does: a new
// Map on each change with every other conversation the same object, and new channel and people
// collections and new row actions on each render. The bench changes one conversation, selects a row
// and renders the parent again (as a clock tick would). `benchRowRenders` counts the rows that
// rendered since its last mark, read from each mounted row's fiber (test/support/mountedRowRenders.ts),
// so the list carries no counter. The data and the render are the list contract's fixture shape
// (test/list-contract/<name>.fixture.tsx: `item`, `change`, `render`), on the same row and scroller
// selectors.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/ui/ui.css";
import "../../src/pages/home-channels/styles.css";
import "../../src/pages/home-channels/ledger.css";
import { useEffect, useState, type CSSProperties } from "react";
import { createRoot } from "react-dom/client";
import { ConversationList } from "../../src/pages/home-channels/ConversationList";
import table from "../../src/pages/home-channels/generated/strings.json";
import type { HomeConversation } from "../../src/pages/home-channels/types";
import { createStrings } from "../../src/pages/shared/i18n";
import { UiProvider } from "../../src/ui/UiProvider";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** A new message's preview in the `index`th conversation, at the same time (it keeps its place). */
    benchChangeOne(index: number): void;
    /** Renders the list's parent again with nothing changed, as a page clock's tick does. */
    benchTick(): void;
  }
}

const params = new URLSearchParams(location.hash.slice(1));
const n = Number(params.get("n") ?? 1000);
/** The first `pins` conversations are pinned (`#n=1000&pins=3`): the Pinned label and its line show. */
const pins = Number(params.get("pins") ?? 0);
const ME = "me";
const START = Date.UTC(2026, 10, 18, 9);
const strings = createStrings(table, ["en"]);

const item = (index: number): HomeConversation => ({
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
  updatedAt: START - index * 60_000,
  lastAt: START - index * 60_000,
  unread: index % 7 === 0 ? 2 : 0,
  mentions: 0,
  muted: false,
  pinned: index < pins,
  ...(index < pins ? { pinPosition: index } : {}),
  lastText: `The last message in conversation ${index}`,
  lastAuthor: `p${index}`,
});
const change = (conversation: HomeConversation): HomeConversation => ({
  ...conversation,
  rev: conversation.rev + 1,
  lastText: `${conversation.lastText} (edited)`,
});

function Bench() {
  const [conversations, setConversations] = useState(
    () => new Map(Array.from({ length: n }, (_, index) => item(index)).map((c) => [c.id, c])),
  );
  const [selected, setSelected] = useState<string | undefined>(undefined);
  const [, setTick] = useState(0);
  // The bench's handles, set once mounted (the setters are stable); ready only once they are.
  useEffect(() => {
    window.benchChangeOne = (index) =>
      setConversations((old) => {
        const id = `c${index}`;
        return new Map(old).set(id, change(old.get(id)!));
      });
    window.benchTick = () => setTick((tick) => tick + 1);
    window.benchReady = true;
  }, []);
  return (
    // The list takes a third of the page, so a narrower window narrows its rows.
    <div className="lg-page" style={{ height: "100vh", "--lg-list": "33%" } as CSSProperties}>
      <ConversationList
        conversations={conversations}
        channels={new Set()}
        people={new Map()}
        activity={new Map()}
        me={ME}
        selected={selected}
        strings={strings}
        onSelect={setSelected}
        onOpenPalette={() => undefined}
        actions={{
          canPin: true,
          onPin: () => undefined,
          onMarkUnread: () => undefined,
          onMarkRead: () => undefined,
          onCopyLink: () => undefined,
        }}
      />
    </div>
  );
}

const root = document.getElementById("root")!;
createRoot(root).render(
  <UiProvider container={root}>
    <Bench />
  </UiProvider>,
);
window.benchRowRenders = mountedRowRenders(() => document.querySelectorAll(".lg-list-group > li"));
