import { useMemo } from "react";
import { componentEntry } from "../../../gallery/format";
import { AppPanelSection } from "../../../apps/scene/panels";
import { SceneRenderer } from "../../../apps/scene/SceneRenderer";
import { SceneStore } from "../../../apps/scene/store";

type Props = { look?: "plain" | "tag" | "compact"; dark?: boolean };
function MockAppSection({ look = "plain" }: Props) {
  const store = useMemo(() => {
    const next = new SceneStore();
    next.apply([
      { op: "create", id: "root", type: "VStack", props: { spacing: 3 } },
      { op: "create", id: "prs", type: "Row", props: { title: "cmux #32944", subtitle: "Remove opaque header backing", symbol: "pullRequest", badge: "open", onTap: true } },
      { op: "create", id: "session", type: "Row", props: { title: "Session app", subtitle: "Local · running", symbol: "terminal" } },
      { op: "create", id: "more", type: "Button", props: { title: "Show all" } },
      { op: "create", id: "tag", type: "Badge", props: { text: "app" } },
      { op: "children", id: "root", children: look === "compact" ? ["prs", "more"] : look === "tag" ? ["tag", "prs", "session", "more"] : ["prs", "session", "more"] },
      { op: "root", id: "root" },
    ]);
    return next;
  }, [look]);
  const section = { id: "app:github-prs#recent", title: "Recent PRs", symbol: "git.pullrequest", node: <SceneRenderer store={store} dispatch={() => undefined} /> } as const;
  return <div className="acpmux-session-info__body"><AppPanelSection section={section} /></div>;
}
export default componentEntry({
  id: "agent-pane.session-info-app-sections",
  title: "Session Info app sections",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 320, normal: 360 },
  covers: ["agent-session/acpmux/session-info/SessionInfo.tsx", "apps/scene"],
  load: async () => MockAppSection,
  variants: {
    plain: { note: "A plain app section with a recent PR and a session row.", props: { look: "plain" } },
    "with-app-tag": { note: "The same app slot with a compact app-like two-row treatment.", props: { look: "tag" } },
    compact: { note: "A capped app section with one PR row and Show all.", props: { look: "compact" } },
  },
});
