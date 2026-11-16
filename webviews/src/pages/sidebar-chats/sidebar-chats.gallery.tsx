// l10n-allow-file: gallery fixtures (public-safe sample chats), not shipped UI.
// The sidebar's chat history blocks (cmux-page://cmux.sidebar-chats/): the page's own mount over the mock
// host, in a 260 wide strip standing in for the sidebar list's gap. The look is the AppKit block's
// (SidebarChatHistoryView, deleted with this page): the header in the section header's quiet style,
// rows at the row height with the row hover fill, Earlier's titles in secondary ink. Chosen: the
// native look (`few-rows` and the rest). `v2-dense-meta` and `v3-no-marks` are the alternatives it was
// weighed against.
import { useEffect, useRef } from "react";
import { componentEntry } from "../../gallery/format";
import { FIXTURE_METRICS, FIXTURE_STRINGS, fixtureBlock, fixtureRows } from "./fixtures";
import type { SidebarChatsBlock } from "./model";

type Props = { block: SidebarChatsBlock; hover?: number };

function SidebarChatsGallery(props: Props) {
  const host = useRef<HTMLDivElement>(null);
  const key = JSON.stringify(props);
  useEffect(() => {
    const root = host.current;
    if (!root) return;
    const { block, hover } = JSON.parse(key) as Props;
    let dispose = () => {};
    let live = true;
    void Promise.all([import("./mount"), import("./mockHost")]).then(
      ([{ mountSidebarChats }, { MockSidebarChatsHost }]) => {
        if (!live) return;
        const chats = mountSidebarChats(root, new MockSidebarChatsHost(block), FIXTURE_STRINGS);
        dispose = chats.unmount;
        // Drawn now, not after the mock's stream answers, so the stage's first frame has the rows.
        chats.show(block);
        if (hover !== undefined) root.querySelectorAll(".sc-row")[hover]?.classList.add("sc-gallery-hover");
      },
    );
    return () => {
      live = false;
      dispose();
    };
  }, [key]);
  return (
    <div className="sidebar-chats-gallery">
      <div className="sidebar-chats-gallery-strip" ref={host} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.sidebar-chats",
  title: "Sidebar chat history",
  area: "Pages",
  height: 420,
  widths: { narrow: 200, normal: 260, wide: 340 },
  covers: ["page:cmux.sidebar-chats", "pages/sidebar-chats/SidebarChats.tsx"],
  keywords: ["sidebar", "chat history", "earlier", "pinned", "recents", "session tree"],
  load: async () => SidebarChatsGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("./sidebar-chats.gallery.css");
  },
  variants: {
    "few-rows": {
      note: "Earlier with three chats and Show More (chosen, ships: the AppKit block's look).",
      props: { block: fixtureBlock() },
    },
    pinned: {
      note: "Pinned: titles in primary ink, a header that does not fold, no Show More.",
      props: { block: fixtureBlock({ part: "pinned", rows: fixtureRows(2), tail: null }) },
    },
    "many-rows": {
      note: "A second page of Earlier (20 rows of the 20-row page size, then Show More); every fifth harness is unknown.",
      props: { block: fixtureBlock({ rows: fixtureRows(20) }) },
    },
    hover: {
      note: "The pointer over the second row: the sidebar's hover fill (there is no selected state; a click opens the chat).",
      props: { block: fixtureBlock(), hover: 1 },
    },
    "long-title": {
      note: "A title longer than the row: it ends in an ellipsis before the age, which keeps its place.",
      props: {
        block: fixtureBlock({
          rows: [
            {
              id: "long",
              title: "Investigate why the sidebar's chat history jumps after a relaunch when the session tree is on",
              meta: "3h",
              harness: "claude-code",
            },
            ...fixtureRows(2, 1),
          ],
        }),
      },
    },
    empty: {
      note: "Empty state: acpmux has not sent Earlier's chats yet, so Earlier keeps its header and a Loading row.",
      props: { block: fixtureBlock({ rows: [], tail: "loading" }) },
    },
    folded: {
      note: "Earlier folded to its header: the chevron points right, no rows.",
      props: { block: fixtureBlock({ folded: true }) },
    },
    "v2-dense-meta": {
      note: "V2 (not chosen): a tighter row (24) with the age in the title's size; denser but off the workspace rows' grid.",
      props: { block: fixtureBlock({ metrics: { ...FIXTURE_METRICS, row: 24, metaSize: 13 } }) },
    },
    "v3-no-marks": {
      note: "V3 (not chosen): no harness marks, titles at the plain text column; quieter, but which agent ran a chat is lost.",
      props: {
        block: fixtureBlock({ rows: fixtureRows(3).map((row) => ({ ...row, harness: null, markColor: null })) }),
      },
    },
  },
});
