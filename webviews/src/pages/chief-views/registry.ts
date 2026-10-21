// The Chief view gallery's manifest: every view, one entry each. Adding a view is one entry here
// and its component; the switcher, the gallery cards, the placement menu and the data loading all
// read this list.
//
// The entry follows the app platform's manifest (CmuxNextApps/Resources/AppPlatform,
// `cmux-app.json`): an id, a name, a one-line description, what it contributes and where it shows
// by default. Those manifests describe sandboxed apps that render through scopes in the app; these
// views are first-party React components on this page's own ops, so the shape is copied, not the
// loader.
import type { ComponentType } from "react";
import type { Strings } from "../shared/i18n";
import type { ChiefViewsSnapshot, ViewNeed } from "./store";
import type { ChiefAgent, Placement } from "./types";
import { AgentBoardView } from "./views/AgentBoard";
import { FleetView } from "./views/Fleet";
import { LandingView } from "./views/Landing";
import { TimelineView } from "./views/Timeline";
import { WhereIsEverybodyView } from "./views/WhereIsEverybody";

/** What every view gets. */
export type ChiefViewProps = {
  data: ChiefViewsSnapshot;
  strings: Strings;
  now: number;
  /** Where it shows now: a sidebar draws narrow rows. */
  placement: Placement;
  onOpenAgent: (agent: ChiefAgent) => void;
  onOpenURL: (url: string) => void;
  onSetFleetURL: (url: string) => Promise<boolean>;
};

export type ChiefViewManifest = {
  /** Lower kebab case, unique; the layout key stores it. */
  id: string;
  /** String keys (Localizable.xcstrings). */
  title: string;
  description: string;
  /** The glyph on its card and switcher dot. */
  glyph: "people" | "board" | "fleet" | "landing" | "timeline";
  component: ComponentType<ChiefViewProps>;
  /** Where "Open" puts it. */
  defaultPlacement: Placement;
  /** On in a new gallery. Only the first view is. */
  defaultOn: boolean;
  /** The data it reads (agents always load). */
  needs: readonly ViewNeed[];
};

export const CHIEF_VIEWS: readonly ChiefViewManifest[] = [
  {
    id: "where-is-everybody",
    title: "chiefViews.view.everybody.title",
    description: "chiefViews.view.everybody.description",
    glyph: "people",
    component: WhereIsEverybodyView,
    defaultPlacement: "pane",
    defaultOn: true,
    needs: ["agents", "fleet"],
  },
  {
    id: "agent-board",
    title: "chiefViews.view.board.title",
    description: "chiefViews.view.board.description",
    glyph: "board",
    component: AgentBoardView,
    defaultPlacement: "pane",
    defaultOn: false,
    needs: ["agents", "landing", "fleet"],
  },
  {
    id: "fleet",
    title: "chiefViews.view.fleet.title",
    description: "chiefViews.view.fleet.description",
    glyph: "fleet",
    component: FleetView,
    defaultPlacement: "split",
    defaultOn: false,
    needs: ["agents", "fleet"],
  },
  {
    id: "landing",
    title: "chiefViews.view.landing.title",
    description: "chiefViews.view.landing.description",
    glyph: "landing",
    component: LandingView,
    defaultPlacement: "split",
    defaultOn: false,
    needs: ["agents", "landing", "fleet"],
  },
  {
    id: "timeline",
    title: "chiefViews.view.timeline.title",
    description: "chiefViews.view.timeline.description",
    glyph: "timeline",
    component: TimelineView,
    defaultPlacement: "sidebar",
    defaultOn: false,
    needs: ["agents", "landing"],
  },
];

export const viewById = (id: string | undefined) => CHIEF_VIEWS.find((view) => view.id === id);
