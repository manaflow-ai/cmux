// l10n-allow-file: gallery fixtures, not shipped UI.
// The project header sticks while you scroll an expanded project (Leo, 2026-11-10); clicking the
// stuck header collapses the project and scrolls back to its top.
// Pick "veil": the stuck header lies on the sidebar's own glass (sidebar tone at 90%, 12 px blur)
// and fades into the rows over 12 px; no line (the Blocks rule) and no shadow (a shadow reads as a
// card lifted above the glass).
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import type { ProjectCapsDesignsProps } from "./ProjectCapsDesigns";

const load = () => import("./ProjectCapsDesigns").then((module) => module.ProjectCapsDesigns);
const covers = ["sidebar/ProjectCapsDesigns.tsx#ProjectCapsDesigns"];
/** Mid-scroll through the cmux project with its first page open (31 rows), so its header sticks. */
const midScroll: Play = (ctx) => ctx.scroll({ selector: ".pcd-scroll" }, 320);
const expanded = { open: { cmux: 1 } };

export default componentEntry<ProjectCapsDesignsProps>({
  id: "sidebar.project-caps.sticky-header",
  title: "Project caps: the sticky project header (decided 2026-11-10)",
  area: "Sidebar",
  covers,
  height: 520,
  keywords: ["sticky", "header", "project", "scroll"],
  load,
  variants: {
    veil: {
      note: "Pick. Stuck header on the sidebar's own glass, a 12 px fade below, no line; click collapses",
      props: { sticky: "veil", ...expanded },
      play: midScroll,
    },
    shadow: {
      note: "Stuck header on the opaque sidebar tone with a soft shadow below",
      props: { sticky: "shadow", ...expanded },
      play: midScroll,
    },
    label: {
      note: "Compact stuck label: only the name gets a small glass capsule; rows pass beside it",
      props: { sticky: "label", ...expanded },
      play: midScroll,
    },
    "veil-rest": {
      note: "Pick at rest (not scrolled): the header is the plain quiet label",
      props: { sticky: "veil", ...expanded },
    },
  },
});
