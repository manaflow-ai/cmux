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
    // An agent is installed and signed in and the Mac has no chats yet: the composer alone (the
    // "Try one" starters were cut on 2026-11-21, first-run cuts).
    "first-run": {
      note: "Shipped: a Mac with an agent and no chats yet sees only the composer and its chips.",
      props: { ...props, snapshot: noChat([]), template: "minimal" },
    },
  },
});
