// l10n-allow-file: gallery fixtures, not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import { noChat } from "../../../gallery/fixtures/acpmux";
import type { NewTabScreen } from "./NewTabScreen";

const props: ComponentProps<typeof NewTabScreen> = {
  snapshot: noChat([], { catalog: [] }),
  home: "/Users/you",
  cwd: "/Users/you",
  projects: [{ cwd: "/Users/you", label: "you" }],
  knownProjects: null,
  onAsk: () => {},
  onOpen: () => {},
  onSearch: () => {},
  onShell: () => {},
  onJump: () => {},
  onOpenSession: () => {},
  onShowAll: () => {},
  onBrowseProject: async () => undefined,
};

export default componentEntry<ComponentProps<typeof NewTabScreen>>({
  id: "agent-pane.first-run",
  title: "First chat without a project",
  area: "New Tab",
  height: 620,
  pane: true,
  covers: ["agent-session/acpmux/newtab/NewTabScreen.tsx", "agent-session/acpmux/newtab/StageCards.tsx"],
  load: () => import("./NewTabScreen").then((module) => module.NewTabScreen),
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  variants: {
    "project-card": {
      note: "Recommended for the existing project-card layout: Browse and No project are direct actions, above the composer.",
      props: { ...props, template: "default" },
    },
    minimal: {
      note: "The default minimal layout keeps its existing folder control beside the composer.",
      props: { ...props, template: "minimal" },
    },
    "minimal-projects": {
      note: "The same empty project card when the user enables the Projects widget in Minimal.",
      props: { ...props, template: "minimal", pageWidgets: new Set(["projects"]) },
    },
  },
});
