// l10n-allow-file: native gallery fixtures are review-only sample data.
import { nativeEntry } from "../gallery/format";

const fixtureRoot = "Packages/macOS/CmuxNext/Tests/Fixtures/SidebarGallery/";

export default nativeEntry({
  id: "sidebar.native-gallery",
  title: "Sidebar native states",
  area: "Native",
  covers: ["swift:SidebarGalleryFixture", "swift:SidebarSessionTree", "swift:SidebarNeedsYouTrayView"],
  height: 680,
  variants: {
    "session-tree-deep": {
      note: "A folded spawn tree with blocked, failed, running and unread roll-up chips.",
      fixture: fixtureRoot + "session-tree-deep.json",
    },
    "sidebar-customization": {
      note: "Representative grouped rows used to review keep-in-place sidebar projection.",
      fixture: fixtureRoot + "sidebar-customization.json",
    },
    "needs-you": {
      note: "The needs-you tray with blocked, failed and finished-unread sessions.",
      fixture: fixtureRoot + "needs-you.json",
    },
  },
});
