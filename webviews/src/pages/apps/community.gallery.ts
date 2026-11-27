// l10n-allow-file: gallery fixtures (public-safe sample registry data), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { CommunityGalleryProps } from "./CommunityGalleryDemo";

export default componentEntry<CommunityGalleryProps>({
  id: "pages.apps.community",
  title: "App Store Community",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: [
    "pages/apps/CommunityView.tsx#CommunityView",
    "pages/apps/community.ts#CommunityStore",
    "pages/apps/AppsPage.tsx#AppsPage",
  ],
  load: async () => (await import("./CommunityGalleryDemo")).CommunityGalleryDemo,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
    await import("./community.css");
  },
  variants: {
    list: {
      note: "The Community tab: an item from another device first with Install on This Mac, then kind chips and the sort menu, then each row's author, downloads and last updated date.",
      props: { hash: "#/community", data: "sample" },
    },
    detail: {
      note: "A community item's page: header with Install, the README rendered (headings, a list, a table, code) and Information with downloads, last updated, version, license and the repository.",
      props: { hash: "#/community?ref=github.com/sample-author/focus-timer", data: "sample" },
    },
    "detail-installed": {
      note: "An installed community item's page: the Installed badge in place of Install.",
      props: { hash: "#/community?ref=github.com/sample-author/teal-twin", data: "sample" },
    },
    installing: {
      note: "Install pressed: the button waits, disabled, while the host's consent card is up.",
      props: { hash: "#/community", data: "holding", install: "github.com/sample-author/focus-timer" },
    },
    empty: {
      note: "The registry has no listings yet: a calm empty state with a link to cmux.com/extensions.",
      props: { hash: "#/community", data: "empty" },
    },
    unreachable: {
      note: "The registry answers route.not_found (not deployed): the same calm empty state, never an error wall.",
      props: { hash: "#/community", data: "unreachable" },
    },
    "older-owner": {
      note: "An owner that refuses the Community source: the same empty state.",
      props: { hash: "#/community", data: "refused" },
    },
  },
});
