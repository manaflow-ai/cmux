// The Chief view gallery's wire shapes (cmux-page://cmux.chief-views/). The app answers every op
// (ChiefViewsPageProvider.swift); the page derives everything else (model.ts), so the Swift side
// stays a plain reader of the stores it already has.

/** The page's ops and its one stream. */
export const ChiefViewsOps = {
  /** `{}` → `ChiefAgentsReply`: every acpmux chat (this Mac and its peers) and terminal agent. */
  agents: "cmux.chief_views.agents",
  /** Stream: one `ChiefAgentsReply` whenever an agent's row changes. */
  agentsChanged: "cmux.chief_views.agents_changed",
  /** `{}` → `FleetReply`, or `cmux.chief_views.fleet_unavailable` with `details.configured`. */
  fleet: "cmux.chief_views.fleet",
  /** `{ url }` (the person's click): the CI dashboard the Fleet view reads. Empty clears it. */
  setFleetURL: "cmux.chief_views.set_fleet_url",
  /** `{}` → `LandingReply`: open and merged-today pull requests of the repository. */
  landing: "cmux.chief_views.landing",
  /** `{ kind, id }` (the person's click): reveals the agent's chat or terminal tab. */
  open: "cmux.chief_views.open",
  /** `{ url }` (the person's click): opens a pull request on Home's right side. */
  openURL: "cmux.chief_views.open_url",
} as const;

/** The page's error codes the views word themselves. */
export const ChiefViewsErrors = {
  fleetUnavailable: "cmux.chief_views.fleet_unavailable",
  landingUnavailable: "cmux.chief_views.landing_unavailable",
} as const;

/** What an agent is doing, in the four words the views use. */
export type AgentState = "working" | "waiting" | "idle" | "failed";

/** One agent: an acpmux chat (`chat`) or an agent in a terminal that reports through a hook. */
export type ChiefAgent = {
  id: string;
  kind: "chat" | "terminal";
  /** acpmux's session name, or the terminal tab's title. */
  name: string;
  /** What the row says it is (acpmux's masked title, else the name). */
  title: string;
  /** `local` for this Mac, else the peer or machine id. */
  machine: string;
  /** The machine's display name; absent for this Mac (the page says "This Mac"). */
  machineName?: string | null;
  /** Its working folder, when the record has one. */
  folder?: string | null;
  state: AgentState;
  /** What it is doing now: acpmux's masked step. Terminal agents have none (their prompts are never sent). */
  task?: string | null;
  /** The last turn's error (failed). */
  error?: string | null;
  /** Unix ms of its last output (acpmux `updatedAt`, a hook's `updated_at_ms`). */
  lastOutputAt?: number | null;
  /** Unix ms since it has been in `state`. */
  since?: number | null;
  /** Unix ms it started; absent when the record does not say. */
  createdAt?: number | null;
  /** The harness ("claude", "codex"). */
  harness?: string | null;
  /** The git branch of its terminal, when it is one. */
  branch?: string | null;
  /** The coordinator that started it (`mux.parent`). */
  parent?: string | null;
};

export type ChiefAgentsReply = { agents: ChiefAgent[] };

/** One machine of the CI fleet dashboard. */
export type FleetMachine = {
  host: string;
  /** One-minute load average. */
  load?: number | null;
  ncpu?: number | null;
  cpuPct?: number | null;
  memFreePct?: number | null;
  runnersBusy: number;
  runnersOnline: number;
  /** The dashboard could not reach it. */
  error?: string | null;
};

/** A pull request the dashboard has a CI run for. */
export type FleetPR = { number: number; title: string; branch?: string | null; status: string };

export type FleetReply = {
  /** ISO time the dashboard last collected. */
  updated?: string | null;
  machines: FleetMachine[];
  queued: number;
  prs: FleetPR[];
};

/** One pull request from the repository's search. */
export type LandingPR = {
  number: number;
  title: string;
  url: string;
  author?: string | null;
  labels: string[];
  draft?: boolean;
  createdAt?: string | null;
  mergedAt?: string | null;
};

export type LandingReply = {
  repo: string;
  base: string;
  open: LandingPR[];
  merged: LandingPR[];
};

/** Where a view opens beside the Chief: the whole area, half of it, or a narrow column. */
export type Placement = "pane" | "split" | "sidebar";
