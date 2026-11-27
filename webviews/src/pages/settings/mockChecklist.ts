// l10n-allow-file: mock fixtures (the checklist's English as the CLI answers it), not shipped UI.
// The Customize cmux checklist as `cmux --json customize checklist` answers it, for the mock host,
// the tests and the gallery. The real steps and their done rule are Rust's (cmux-customize
// `checklist.rs`); this mirrors them only far enough to draw: a step is done when the mock holds a
// value for a key it watches, the page reported its connection, or it was checked off by hand.
import type { Checklist, ChecklistFact, ChecklistStep } from "./ops";

type MockStep = { id: string; title: string; detail: string; route: string; keys?: string[]; fact?: ChecklistFact };

const STEPS: MockStep[] = [
  {
    id: "theme",
    title: "Pick a theme",
    detail: "Colors for the terminal and the window.",
    route: "/settings/appearance?focus=card.themeStudio",
    keys: ["appearance.theme"],
  },
  {
    id: "look",
    title: "Try a look",
    detail: "A whole look at once, kept in your Customization Library.",
    route: "/settings/appearance?focus=card.customizeLibrary",
  },
  {
    id: "background",
    title: "Choose a background",
    detail: "A picture or color behind your work.",
    route: "/settings/appearance?focus=card.backdrops",
    keys: ["appearance.background"],
  },
  {
    id: "textSize",
    title: "Set text size and density",
    detail: "How big and how roomy the sidebar, tabs and chat are.",
    route: "/settings/general?focus=card.textSize",
    keys: ["appearance.metrics.chromeFontSize", "appearance.density"],
  },
  {
    id: "sidebar",
    title: "Arrange the sidebar",
    detail: "Its side, look and what each row shows.",
    route: "/settings/sidebar",
  },
  { id: "chat", title: "Tune the chat", detail: "Chat text, font and width.", route: "/settings/chat" },
  { id: "newTab", title: "Choose your New Tab page", detail: "What a new tab opens on.", route: "/settings/newTab" },
  {
    id: "terminalFont",
    title: "Pick a terminal font",
    detail: "The font and size of your terminals.",
    route: "/settings/terminal",
    keys: ["terminal.fontFamily", "terminal.fontSize"],
  },
  {
    id: "shortcut",
    title: "Set a keyboard shortcut",
    detail: "Put any action on the keys you want.",
    route: "/settings/keyboard",
  },
  {
    id: "notifications",
    title: "Set up notifications",
    detail: "When cmux tells you an agent is done or needs you, and how.",
    route: "/settings/notifications",
  },
  {
    id: "agents",
    title: "Choose your agents and models",
    detail: "Sign in to the models your chats use.",
    route: "/settings/models",
    fact: "models",
  },
  {
    id: "agentDefaults",
    title: "Set agent defaults",
    detail: "What a new chat may do without asking, and its guidance.",
    route: "/settings/agents",
  },
  {
    id: "mcp",
    title: "Connect an MCP server",
    detail: "Give your agents a service's tools.",
    route: "/settings/mcpServers",
    fact: "mcp",
  },
  {
    id: "github",
    title: "Connect GitHub",
    detail: "Pull requests and repositories in cmux.",
    route: "/settings/accounts",
    fact: "github",
  },
  {
    id: "phone",
    title: "Pair your phone",
    detail: "Follow your chats away from the Mac.",
    route: "/settings/mobile",
    fact: "phone",
  },
];

/** The checklist for the values the mock holds (`values`), the connections `has` and the ids checked
 * off by hand (`customize.checklist.done`). */
export function mockChecklist(
  values: ReadonlyMap<string, unknown> = new Map(),
  has: readonly ChecklistFact[] = [],
): Checklist {
  const checked = values.get("customize.checklist.done");
  const hand = new Set(Array.isArray(checked) ? checked : []);
  const steps: ChecklistStep[] = STEPS.map((step) => {
    const done_by =
      step.keys?.some((key) => values.has(key)) === true
        ? "setting"
        : step.fact && has.includes(step.fact)
          ? "connected"
          : hand.has(step.id)
            ? "checked"
            : null;
    return {
      id: step.id,
      title: { key: `settingsPage.customizeProgress.step.${step.id}`, text: step.title },
      detail: { key: `settingsPage.customizeProgress.step.${step.id}.detail`, text: step.detail },
      route: step.route,
      done: done_by !== null,
      done_by,
    };
  });
  const done = steps.filter((step) => step.done).length;
  return {
    enabled: values.get("customize.checklist.enabled") !== false,
    done,
    total: steps.length,
    next: steps.find((step) => !step.done)?.id ?? null,
    steps,
  };
}

/** A checklist with the first `count` steps checked off by hand. */
export function mockChecklistDone(count: number): Checklist {
  return mockChecklist(new Map([["customize.checklist.done", STEPS.slice(0, count).map((step) => step.id)]]));
}
