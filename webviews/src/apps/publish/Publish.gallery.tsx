// l10n-allow-file: gallery fixture text, not shipped UI.
// The Apps tier (RFD 0003 E-A and E-C, behind experiments.appsTier): the browser pane's Publish
// popover and the sidebar's Apps section. Each variant is the Rust rules' answer
// (cmux-tui/crates/cmux-apps/src/ui.rs, ops apps_tier_*) for a sample page, draft, run or list.
import { componentEntry } from "../../gallery/format";
import type { AppsPublishPreviewProps } from "./AppsPublishPreview";
import * as fx from "./fixtures";

export default componentEntry<AppsPublishPreviewProps>({
  id: "apps.publish",
  title: "Apps tier: Publish and Apps section",
  area: "Apps",
  experimental: true,
  height: 420,
  keywords: ["apps tier", "publish", "preview", "appsTier", "rfd 0003", "sidebar section"],
  covers: ["apps/publish/AppsPublishPreview.tsx"],
  load: async () => (await import("./AppsPublishPreview")).AppsPublishPreview,
  variants: {
    "popover-private": {
      note: "Chosen: the Publish press on a Cloud preview. The name starts from the page title, the audience is Only me (RFD G3), and the start command is inferred on the machine from the port.",
      props: { popover: fx.popoverPrivate, section: fx.section },
    },
    "popover-team": {
      note: "A typed name and My team: the slug follows the name and the run adds --share team.",
      props: { popover: fx.popoverTeam },
    },
    "name-empty": {
      note: "A name with no letter or digit makes no slug: Publish is disabled and the field says why.",
      props: { popover: fx.popoverNameEmpty },
    },
    published: {
      note: "The run answered: v3 is live at the app's URL, with Open.",
      props: { popover: fx.popoverPrivate, outcome: fx.published },
    },
    failed: {
      note: "The new version failed its probe: the code and message show, and the live version stays (G2).",
      props: { popover: fx.popoverPrivate, outcome: fx.failed },
    },
    "sidebar-section": {
      note: "The Apps section: pinned first, then by title; live and not-live dots; + Publish preview… last.",
      props: { section: fx.section },
    },
    "sidebar-empty": {
      note: "No apps yet: only the + Publish preview… row.",
      props: { section: fx.sectionEmpty },
    },
    "sidebar-error": {
      note: "The list was refused: a note, never an empty list.",
      props: { section: fx.sectionError },
    },
  },
});
