// The empty Chief conversation's first-run panel, as values: which intro shows (Swift
// `ChiefIntroStore` and `ChiefIntroKind`), the starter prompts (`HomeStarterContext`), the
// Switching card's lines (`HomeSwitchKeys`), the agents at a glance (`HomeAgentGlance`), and what
// fits above the composer (`HomeFirstRunView.fitAgentRows`). The host keeps the flags and runs the
// actions through the ops below; the swap PR wires them.
import type { Strings } from "../strings";

/** Page → host ops of the first-run panel. */
export const FIRST_RUN_OPS = {
  /** `{action}`: a row's action (`HomeFirstRunAction`): a terminal tab, a new agent chat, the Chief
   * pet's Show / Hide, memory import. */
  action: "cmux.home.firstRun.action",
  /** `{id}`: an agent row's daemon tab, opened. */
  openAgent: "cmux.home.firstRun.openAgent",
  /** `{}`: the Switching card's Hide, recorded so it never shows again. */
  hideSwitchKeys: "cmux.home.firstRun.hideSwitchKeys",
  /** `{}`: the Switching card's note button: System Settings > Keyboard > Keyboard Shortcuts. */
  openKeyboardSettings: "cmux.home.firstRun.openKeyboardSettings",
  /** `{kind, conversation}`: the intro showed (`ChiefIntroStore.markShown`); it never returns. */
  markIntroShown: "cmux.home.firstRun.markIntroShown",
} as const;

/** What a first-run row asks the app to do. */
export type FirstRunAction = "openTerminal" | "startAgent" | "togglePet" | "importMemories";

/** Which first-open intro a Chief's empty conversation shows. */
export type ChiefIntroKind = "welcome" | "askFocus";

/** The intro flags the host keeps (UserDefaults `home.firstRun.chiefIntroShown` and
 * `home.firstRun.chiefIntroAsked`). */
export interface ChiefIntroFlags {
  /** This install had its welcome. */
  welcomeShown: boolean;
  /** The Chief conversations that asked for their focus. */
  asked: readonly string[];
}

/** The intro `conversation` shows now: the welcome for the person's only Chief (once per install),
 * else the focus question (once per Chief); undefined when it has nothing to show. */
export function chiefIntro(
  flags: ChiefIntroFlags,
  conversation: string,
  otherChiefs: number,
): ChiefIntroKind | undefined {
  if (otherChiefs === 0) return flags.welcomeShown ? undefined : "welcome";
  return flags.asked.includes(conversation) ? undefined : "askFocus";
}

/** The flags after `kind` showed on `conversation`. */
export function markIntroShown(flags: ChiefIntroFlags, kind: ChiefIntroKind, conversation: string): ChiefIntroFlags {
  if (kind === "welcome") return { ...flags, welcomeShown: true };
  return { ...flags, asked: [...new Set([...flags.asked, conversation])].sort() };
}

/** The intro's text. */
export function chiefIntroText(kind: ChiefIntroKind, strings: Strings): string {
  return strings.t(kind === "welcome" ? "home.firstRun.intro" : "home.firstRun.introFocus");
}

/** Facts from the app's live mirrors, used only before a Chief conversation starts. */
export interface StarterContext {
  workspaces?: readonly string[];
  working?: readonly string[];
  failures?: readonly string[];
  pullRequests?: readonly string[];
}

/** Three to five prompts; missing activity gets setup questions, never invented work. Each is both
 * the chip's label and the exact message sent. */
export function starterPrompts(context: StarterContext, strings: Strings): string[] {
  const { workspaces = [], working = [], failures = [], pullRequests = [] } = context;
  const result: string[] = [];
  if (failures[0]) result.push(strings.format("home.starter.failure", failures[0]));
  if (working[0]) result.push(strings.format("home.starter.running", working[0]));
  if (pullRequests[0]) result.push(strings.format("home.starter.review", pullRequests[0]));
  for (const name of workspaces) {
    if (!name) continue;
    const prompt = strings.format("home.starter.workspace", name);
    if (!result.includes(prompt)) result.push(prompt);
    if (result.length === 5) break;
  }
  const setup = [
    workspaces.length === 0 ? strings.t("home.starter.setup") : undefined,
    working.length === 0 ? strings.t("home.starter.agent") : undefined,
    strings.t("home.starter.task"),
  ];
  for (const prompt of setup) if (prompt && result.length < 3) result.push(prompt);
  return result;
}

/** What the Switching card shows: each key as the live binding table has it (absent hides that
 * line), and whether Mission Control takes the tabs-by-number keys first. */
export interface SwitchKeys {
  tabByNumber?: string;
  workspaceByNumber?: string;
  nextPreviousTab?: string;
  nextPreviousWorkspace?: string;
  focusBackForward?: string;
  desktopConflict?: boolean;
}

/** The card's lines in order: a label and its keys; keys nothing runs are left out. */
export function switchKeyLines(keys: SwitchKeys, strings: Strings): { label: string; keys: string }[] {
  const lines: [string, string | undefined][] = [
    ["home.firstRun.switchKeys.tabs", keys.tabByNumber],
    ["home.firstRun.switchKeys.workspaces", keys.workspaceByNumber],
    ["home.firstRun.switchKeys.nextTab", keys.nextPreviousTab],
    ["home.firstRun.switchKeys.nextWorkspace", keys.nextPreviousWorkspace],
    ["home.firstRun.switchKeys.focus", keys.focusBackForward],
  ];
  return lines.flatMap(([key, value]) => (value ? [{ label: strings.t(key), keys: value }] : []));
}

/** What an agent is doing, most urgent first (the list's order). */
export type AgentGlanceStatus = "needsYou" | "failed" | "done" | "idle" | "working";
const GLANCE_RANK: Record<AgentGlanceStatus, number> = { needsYou: 0, failed: 1, done: 2, idle: 3, working: 4 };

/** One of the person's agents as the empty Chief conversation lists it: its tab, the name its tab
 * shows, its icon and one word for what it is doing, mapped by the host from the same tab status
 * the tab strip and the sidebar draw. */
export interface AgentGlance {
  /** The daemon tab id the host opens on click. */
  id: string;
  title: string;
  /** A cmux icon name. */
  icon: string;
  status: AgentGlanceStatus;
}

/** At most `limit` agents, most urgent first; the same status keeps the given (sidebar) order. */
export function agentShortlist(agents: readonly AgentGlance[], limit = 5): AgentGlance[] {
  return agents
    .map((agent, index) => ({ agent, index }))
    .sort((a, b) => GLANCE_RANK[a.agent.status] - GLANCE_RANK[b.agent.status] || a.index - b.index)
    .slice(0, limit)
    .map(({ agent }) => agent);
}

/** The panel's fixed geometry (CSS px at scale 1; firstRun.css uses the same numbers). */
export const FIRST_RUN_GEOMETRY = { row: 28, gap: 8, group: 16, heroGap: 24 } as const;

/** The measured parts the panel fits. */
export interface FirstRunMeasure {
  /** The room above the composer. */
  available: number;
  actionCount: number;
  /** The Switching card's height; 0 when it has no keys. */
  card: number;
  /** The intro's height; undefined when no intro shows. */
  intro?: number;
  hero: number;
  /** The starters' height; 0 with no prompts. */
  starters: number;
  /** The "Your agents" heading's height. */
  header: number;
  agentCount: number;
}

/** Which parts show. */
export interface FirstRunFit {
  actions: boolean;
  card: boolean;
  intro: boolean;
  hero: boolean;
  starters: boolean;
  /** How many agent rows show (the heading with the first). */
  agents: number;
}

/** Shows only what fits above the composer, so the panel never runs under it: agent rows go first,
 * least urgent first, then the starters, the hero, the intro, the Switching card, then the action
 * rows together (`HomeFirstRunView.fitAgentRows`). */
export function fitFirstRun(m: FirstRunMeasure): FirstRunFit {
  const { row, gap, group, heroGap } = FIRST_RUN_GEOMETRY;
  const actions = m.actionCount * row + Math.max(0, m.actionCount - 1) * gap;
  const actionsFit = actions <= m.available;
  const wantsCard = m.card > 0;
  const cardPart = group + m.card;
  const cardFits = wantsCard && actionsFit && actions + cardPart <= m.available;
  const card = cardFits ? cardPart : 0;
  const wantsIntro = m.intro !== undefined;
  const introPart = wantsIntro ? m.intro! + heroGap : 0;
  const introFits = wantsIntro && actionsFit && actions + card + introPart <= m.available;
  const introSpace = introFits ? introPart : 0;
  const heroPart = m.hero + heroGap;
  const heroFits = actionsFit && cardFits === wantsCard && actions + card + introSpace + heroPart <= m.available;
  const starterPart = m.starters > 0 ? m.starters + group : 0;
  const startersFit =
    m.starters > 0 &&
    actionsFit &&
    actions + card + introSpace + (heroFits ? heroPart : 0) + starterPart <= m.available;
  const base = actions + card + introSpace + (heroFits ? heroPart : 0) + (startersFit ? starterPart : 0);
  const header = group + m.header;
  let shown = heroFits && cardFits === wantsCard && introFits === wantsIntro ? m.agentCount : 0;
  while (shown > 0 && base + header + shown * (gap + row) > m.available) shown--;
  return {
    actions: actionsFit,
    card: cardFits,
    intro: introFits,
    hero: heroFits,
    starters: startersFit,
    agents: shown,
  };
}
