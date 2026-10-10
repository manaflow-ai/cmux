// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../gallery/format";
import type { AllChatsDesignsProps } from "./AllChatsDesigns";

export default componentEntry<AllChatsDesignsProps>({
  id: "sidebar.all-chats",
  title: "All chats (sidebar bottom): minimal designs",
  area: "Sidebar",
  covers: ["sidebar/AllChatsDesigns.tsx"],
  pick: { beadId: "cx-xub5", recommendedId: "age" },
  load: () => import("./AllChatsDesigns").then((module) => module.AllChatsDesigns),
  variants: {
    quiet: { note: "Harness glyph + title; search and filter icons on hover", props: { design: "quiet", hover: true } },
    age: { note: "Title + faint age on the right; no glyphs; icons on hover", props: { design: "age", hover: true } },
    project: { note: "Title · project; one More icon on hover", props: { design: "project", hover: true } },
  },
});
