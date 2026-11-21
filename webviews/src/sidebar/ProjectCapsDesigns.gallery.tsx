// l10n-allow-file: gallery fixtures, not shipped UI.
// Leo, 2026-11-10: each project shows its first 5 quiet chats, then "Show N more", expanding
// inline 20 at a time in the one sidebar scroll; "Show less" once fully open.
// Pick "text": the quiet secondary-ink "Show 20 more" with a chevron, ChatGPT's row: it names the
// count without a chip on the trail column (where a chip reads as an unread badge beside the blue
// dot and spinner), and "Show less" is the same row with the chevron turned up.
// Siblings: ProjectCapsSticky.gallery.tsx (sticky header), ProjectCapsNeedsYou.gallery.tsx.
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import type { ProjectCapsDesignsProps } from "./ProjectCapsDesigns";

const load = () => import("./ProjectCapsDesigns").then((module) => module.ProjectCapsDesigns);
const covers = ["sidebar/ProjectCapsDesigns.tsx"];
/** The cmux project fully open (both pages): its last row reads "Show less". */
const allOpen = { cmux: 9 };
const capped = ["cmux", "ghostty", "hq"];
/** Motion preview: the first page opens and the rows below slide down together. */
const expand: Play = (ctx) => ctx.click({ selector: '.pcd-project[data-project="cmux"] .pcd-more' });
/** A fully open project is taller than the stage: scroll to its last row. */
const toEnd: Play = (ctx) => ctx.scroll({ selector: ".pcd-scroll" }, "bottom");

export default componentEntry<ProjectCapsDesignsProps>({
  id: "sidebar.project-caps.show-more",
  title: "Project caps: the Show more row (decided 2026-11-10)",
  area: "Sidebar",
  covers,
  height: 560,
  keywords: ["show more", "show less", "cap", "recents", "project"],
  load,
  variants: {
    text: {
      note: "Pick. 'Show 20 more' + chevron in the member text column, secondary ink (ChatGPT)",
      props: { showMore: "text", projects: capped },
    },
    "text-less": {
      note: "Pick, fully open: 'Show less' with the chevron turned up, same row",
      props: { showMore: "text", projects: ["cmux"], open: allOpen },
      play: toEnd,
    },
    "text-expand": {
      note: "Pick, motion: clicking Show more opens 20 rows; the rows below slide down together",
      props: { showMore: "text", projects: capped },
      play: expand,
    },
    chip: {
      note: "'Show more' with a trailing count chip on the trail column",
      props: { showMore: "chip", projects: capped },
    },
    "chip-less": {
      note: "Chip, fully open: 'Show less' and an up chevron on the trail column",
      props: { showMore: "chip", projects: ["cmux"], open: allOpen },
      play: toEnd,
    },
    dots: {
      note: "Compact '··· 20 more': the glyph in the icon column, tertiary ink",
      props: { showMore: "dots", projects: capped },
    },
    "dots-less": {
      note: "Compact, fully open: an up chevron in the icon column and 'Show less'",
      props: { showMore: "dots", projects: ["cmux"], open: allOpen },
      play: toEnd,
    },
    lead: {
      note: "Claude-like: 'Show more' on the lead column, no count, no chevron",
      props: { showMore: "lead", projects: capped },
    },
    "lead-less": {
      note: "Claude-like, fully open: 'Show less' on the lead column",
      props: { showMore: "lead", projects: ["cmux"], open: allOpen },
      play: toEnd,
    },
  },
});
