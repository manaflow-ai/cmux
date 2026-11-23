// l10n-allow-file: gallery fixture text, not shipped UI.
// The example extension examples/extensions/pr-list (a cmux.section/1 on cmux.watch("github.pulls"))
// in each watch status, drawn by the web scene renderer from the same ops its render export emits.
// The sidebar draws app sections natively; this entry is the scene's states, not the sidebar chrome.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp, type SceneProps } from "./store";

type State = "fresh" | "stale" | "loading" | "error" | "empty";
type Props = { state?: State };

const pull = (title: string, subtitle: string, symbol: string, tint: string, badge?: string): SceneProps =>
  badge ? { title, subtitle, symbol, tint, badge } : { title, subtitle, symbol, tint };
const PULLS: SceneProps[] = [
  pull("Keep chat drafts on reconnect", "acme/atlas #184", "eye", "warning", "Review"),
  pull("Show the preview beside the chat", "acme/atlas #181", "arrow.triangle.pull", "success"),
  pull("Refresh the repository list", "acme/atlas #176 · Draft", "circle.dashed", "secondary"),
  pull("Sidebar sections follow the theme", "acme/sidebar #52", "arrow.triangle.pull", "success"),
];
const ERROR_MESSAGE = "Connect GitHub in Settings > Integrations, or set a GitHub login in this extension's settings.";

/** The ops renderPullRequests emits for one watch state (examples/extensions/pr-list/src/main.ts). */
function sceneFor(state: State): SceneOp[] {
  const rows: SceneProps[] = [];
  if (state === "stale")
    rows.push({
      title: "Couldn't refresh",
      subtitle: "GitHub answered 502. Updated 6 min ago.",
      symbol: "exclamationmark.triangle",
      tint: "warning",
      help: "Click to try again",
      onTap: true,
    });
  if (state === "loading")
    rows.push({ title: "Loading pull requests…", symbol: "arrow.triangle.2.circlepath", tint: "secondary" });
  if (state === "fresh" || state === "stale")
    for (const pull of PULLS) rows.push({ ...pull, onTap: true, opacity: state === "stale" ? 0.6 : 1 });
  const ops: SceneOp[] = [{ op: "create", id: "root", type: "VStack", props: { spacing: 2 } }];
  rows.forEach((props, index) => ops.push({ op: "create", id: `row-${index}`, type: "Row", props }));
  const children = rows.map((_, index) => `row-${index}`);
  if (state === "error" || state === "empty") {
    ops.push({
      op: "create",
      id: "empty",
      type: "EmptyState",
      props:
        state === "error"
          ? { title: "Can't load pull requests", message: ERROR_MESSAGE, symbol: "exclamationmark.triangle" }
          : { title: "Nothing open, nothing to review", symbol: "checkmark.circle" },
    });
    children.push("empty");
  }
  ops.push({ op: "children", id: "root", children }, { op: "root", id: "root" });
  return ops;
}

function PrListSection({ state = "fresh" }: Props) {
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(sceneFor(state), true);
    return s;
  });
  return <SceneRenderer store={store} dispatch={() => {}} />;
}

export default componentEntry<Props>({
  id: "apps.pr-list-section",
  title: "PR list section (example extension)",
  area: "Apps",
  pane: true,
  height: 320,
  widths: { narrow: 240, normal: 280 },
  keywords: ["pull requests", "cmux.watch", "signals", "extension", "sidebar section"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => PrListSection,
  variants: {
    fresh: {
      note: "Chosen: the last read succeeded. Review requests lead with the eye symbol, a warning tint and a Review badge; your own PRs follow, drafts dimmed by their symbol.",
      props: { state: "fresh" },
    },
    stale: {
      note: "A re-read failed: the last list stays (stale-while-revalidate), dimmed, under one row that says why and when it last worked; clicking it retries.",
      props: { state: "stale" },
    },
    loading: {
      note: "The first read is in flight: one quiet row, no spinner wall.",
      props: { state: "loading" },
    },
    error: {
      note: "No value and the read failed (no GitHub connection and no login): the empty state says what to do.",
      props: { state: "error" },
    },
    empty: {
      note: "Fresh and empty.",
      props: { state: "empty" },
    },
  },
});
