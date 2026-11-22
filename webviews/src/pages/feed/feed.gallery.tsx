// l10n-allow-file: gallery fixtures, not shipped UI.
// The Feed page (cmux-page://cmux.feed/): the same FeedPage main.tsx mounts, over the mock
// `cmux.feed.*` provider instead of the daemon, on a fixed clock so every capture says the same ages.
//
// Inbox layouts: `split` (the default) keeps the Swift Inbox's 330px column beside the detail, so
// the list and the item read together at the window sizes the Inbox opens at; `compact` narrows the
// column for a small window; `stacked` puts the column over the detail for a narrow pane.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { UiProvider } from "../../ui/UiProvider";
import { createStrings } from "../shared/i18n";
import { FeedPage, rejectText } from "./FeedPage";
import table from "./generated/strings.json";
import { manyNotices, MockFeedProvider, sampleFeed, type MockFeedOptions } from "./mockProvider";
import { FeedStore } from "./store";

const NOW = Date.parse("2026-11-06T15:00:00Z");

type Props = {
  hash: string;
  items?: "sample" | "empty" | "many";
  options?: MockFeedOptions;
  /** After the first read: select an item, switch tab, type a filter, or try an answer. */
  select?: string;
  connection?: "github" | "reports";
  query?: string;
  refuse?: boolean;
};

function FeedGallery({ hash, items = "sample", options = {}, select, connection, query, refuse }: Props) {
  const [strings] = useState(() => createStrings(table, ["en"]));
  const [store] = useState(() => {
    const seed = items === "empty" ? [] : items === "many" ? manyNotices(NOW, 600) : sampleFeed(NOW);
    const provider = new MockFeedProvider(seed, { now: () => NOW, ...options });
    return new FeedStore(provider, hash, {
      clock: () => NOW,
      tzOffsetMin: () => 0,
      rejectText: (reject) => rejectText(reject, strings),
    });
  });
  const [host, setHost] = useState<HTMLElement | null>(null);
  useEffect(() => {
    let live = true;
    void store.start().then(() => {
      if (!live) return;
      if (connection) store.setConnection(connection);
      if (query) store.setQuery(query);
      if (select) store.select(select);
      if (refuse) store.approve("fi_claude_rm_build", "allow");
    });
    return () => {
      live = false;
      store.stop();
    };
  }, [store, connection, query, select, refuse]);
  return (
    <div ref={setHost} style={{ height: "100%" }}>
      {host && (
        <UiProvider container={host}>
          <FeedPage store={store} strings={strings} />
        </UiProvider>
      )}
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.feed",
  title: "Feed",
  area: "Pages",
  experimental: true,
  height: 720,
  widths: { narrow: 360, normal: 760, wide: 1100 },
  covers: [
    "page:cmux.feed",
    "pages/feed/FeedPage.tsx",
    "pages/feed/InboxView.tsx",
    "pages/feed/ListView.tsx",
    "pages/feed/NeedsYouView.tsx",
    "pages/feed/ReportsView.tsx",
    "pages/feed/AnswerControls.tsx",
    "pages/feed/parts.tsx",
    "pages/feed/icons.tsx",
  ],
  load: async () => FeedGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("../../ui/controls.css");
    await import("./styles.css");
  },
  variants: {
    "inbox-split": {
      note: "Default. The Inbox: groups with counts in a 330px column beside a request's detail.",
      props: { hash: "#/inbox", select: "fi_codex_question" },
    },
    "inbox-compact": {
      note: "A narrower column and tighter detail for a small window.",
      props: { hash: "#/inbox?density=compact", select: "fi_claude_rm_build" },
    },
    "inbox-stacked": {
      note: "The column over the detail, for a narrow pane.",
      props: { hash: "#/inbox?density=stacked", select: "fi_build_done" },
    },
    "inbox-github": {
      note: "The GitHub tab: a review request with its checks, actions and comment field.",
      props: { hash: "#/inbox", options: { githubEnabled: true }, connection: "github", select: "fi_github_review" },
    },
    "inbox-reports": {
      note: "The reports basket and its reply field.",
      props: { hash: "#/inbox", connection: "reports" },
    },
    "inbox-empty": { note: "Nothing in the Inbox.", props: { hash: "#/inbox", items: "empty" } },
    "inbox-no-matches": { note: "A filter that matches nothing.", props: { hash: "#/inbox", query: "zzz" } },
    "inbox-pending": {
      note: "Items the owner has not settled yet are dimmed and their answers off.",
      props: {
        hash: "#/inbox",
        options: { pending: ["fi_claude_rm_build", "fi_codex_question"] },
        select: "fi_claude_rm_build",
      },
    },
    "inbox-many": {
      note: "600 notices: the list draws only the rows near the viewport.",
      props: { hash: "#/inbox", items: "many" },
    },
    "inbox-disconnected": {
      note: "The owner lost its cloud link: the banner, and answers off.",
      props: { hash: "#/inbox", options: { connection: { state: "disconnected", reason: "" } } },
    },
    "list-sidebar": {
      note: "The list in the right sidebar: request cards with inline answers, then rows, on a transparent background.",
      props: { hash: "#/list?surface=sidebar" },
    },
    "list-refused": {
      note: "An answer the owner refused shows the shared toast.",
      props: { hash: "#/list", options: { refuse: "feed.moving" }, refuse: true },
    },
    "list-empty": { note: "Nothing new.", props: { hash: "#/list", items: "empty" } },
    "needs-you-rows": { note: "Needs you as rows, with the count and N more.", props: { hash: "#/needs-you" } },
    "needs-you-cards": { note: "Needs you as cards with inline answers.", props: { hash: "#/needs-you?style=cards" } },
    "needs-you-bar": { note: "Needs you as one line.", props: { hash: "#/needs-you?style=bar" } },
  },
});
