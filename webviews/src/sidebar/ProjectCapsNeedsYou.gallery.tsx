// l10n-allow-file: gallery fixtures, not shipped UI.
// "Needs you" at the very top of the sidebar, only when non-empty (Leo, 2026-11-10): yellow rows
// first then blue, at most 3, then "N more"; collapsible.
// Pick "rows": plain rows under the same quiet header as a project; the tinted card reads as a notice.
import { componentEntry } from "../gallery/format";
import type { ProjectCapsDesignsProps } from "./ProjectCapsDesigns";

const load = () => import("./ProjectCapsDesigns").then((module) => module.ProjectCapsDesigns);
const covers = ["sidebar/ProjectCapsDesigns.tsx#ProjectCapsDesigns"];
const capped = ["cmux", "ghostty", "hq"];

export default componentEntry<ProjectCapsDesignsProps>({
  id: "sidebar.project-caps.needs-you",
  title: "Project caps: the Needs you section (decided 2026-11-10)",
  area: "Sidebar",
  covers,
  height: 520,
  keywords: ["needs you", "waiting", "unread", "attention"],
  load,
  variants: {
    rows: {
      note: "Pick. Yellow rows then blue, at most 3, then '2 more'; quiet header folds it",
      props: { needsYou: "rows", projects: capped },
    },
    tinted: {
      note: "The same rows on a faint yellow-tinted card",
      props: { needsYou: "tinted", projects: capped },
    },
    collapsed: {
      note: "Folded: the header with a count chip (5)",
      props: { needsYou: "rows", needsYouCollapsed: true, projects: capped },
    },
  },
});
