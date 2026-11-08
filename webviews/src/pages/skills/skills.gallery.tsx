import { componentEntry } from "../../gallery/format";
import { SkillsPage } from "./SkillsPage";
import { MockSkillsProvider, sampleEntries } from "./mockProvider";

function Gallery({
  mode = "default",
}: {
  mode?: "default" | "filtered" | "empty";
}) {
  const entries =
    mode === "empty"
      ? []
      : mode === "filtered"
        ? sampleEntries.filter((entry) => entry.kind === "mcp")
        : sampleEntries;
  return (
    <SkillsPage client={new MockSkillsProvider()} initialEntries={entries} />
  );
}

export default componentEntry<{ mode?: "default" | "filtered" | "empty" }>({
  id: "pages.skills",
  title: "Skills directory",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["page:cmux.skills", "pages/skills/SkillsPage.tsx"],
  load: async () => Gallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    discover: {
      note: "The full directory with installed and available entries.",
      props: { mode: "default" },
    },
    "mcp-filter": {
      note: "MCP servers filtered into a focused view.",
      props: { mode: "filtered" },
    },
    empty: {
      note: "An empty search result keeps the filters and explains the next step.",
      props: { mode: "empty" },
    },
  },
});
