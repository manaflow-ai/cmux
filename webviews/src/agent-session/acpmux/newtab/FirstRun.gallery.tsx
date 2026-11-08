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
  covers: [
    "agent-session/acpmux/newtab/NewTabScreen.tsx",
    "agent-session/acpmux/newtab/StageCards.tsx",
    "agent-session/acpmux/newtab/FirstRunStarters.tsx",
  ],
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
    // An agent is installed and signed in (the catalog is in) and the Mac has no chats yet: the
    // starters show under the composer. Three looks; rows ship.
    "starters-rows": {
      note: "Shipped: three quiet rows with an icon under the composer, a wash only on hover. A pick fills the composer and sends nothing.",
      props: { ...props, snapshot: noChat([]), template: "minimal" },
    },
    "starters-inline": {
      note: "One centred line of plain text actions. Quietest, but three prompts on one line wrap at narrow widths.",
      props: { ...props, snapshot: noChat([]), template: "minimal", starterLook: "inline" },
    },
    "starters-card": {
      note: "The rows inside the stage card's surface. Reads as a second composer-weight object on an otherwise empty page.",
      props: { ...props, snapshot: noChat([]), template: "minimal", starterLook: "card" },
    },
    "starters-project-card": {
      note: "The Default layout with the project card above and the shipped rows under the composer.",
      props: { ...props, snapshot: noChat([]), template: "default" },
    },
  },
});
