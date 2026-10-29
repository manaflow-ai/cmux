// l10n-allow-file: gallery fixtures are product-shaped sample artifacts, not shipped copy.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { ArtifactsPage } from "./ArtifactsPage";
import { MockArtifactsProvider } from "./mockProvider";
import { ArtifactsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";
function Gallery({ focus = "html", empty = false }: { focus?: "html" | "markdown"; empty?: boolean }) {
  const [store] = useState(() => new ArtifactsStore(empty ? null : new MockArtifactsProvider()));
  useEffect(() => { if (focus === "markdown") void store.select("memory/codex/artifacts-pane.md"); }, [focus, store]);
  return <ArtifactsPage store={store} />;
}
export default componentEntry({
  id: "pages.artifacts",
  title: "Artifacts",
  area: "Pages",
  experimental: true,
  height: 640,
  widths: { narrow: 720, normal: 980, wide: 1280 },
  covers: ["page:cmux.artifacts", "pages/artifacts/ArtifactsPage.tsx", "@pierre/trees", "@pierre/diffs"],
  load: async () => Gallery,
  styles: async () => { await import("../shared/pageBase.css"); await import("./styles.css"); },
  variants: {
    "html-preview": { note: "An HTML artifact is isolated in a sandboxed opaque-origin frame; its history and commit trailers stay visible.", props: {} },
    markdown: { note: "Markdown and JSON files remain read-only text while the history diff stays available.", props: { focus: "markdown" } },
    "empty-state": { note: "The tree and main pane retain a calm empty state before a file is selected.", props: { empty: true } },
  },
});
