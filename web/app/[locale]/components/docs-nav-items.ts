export type NavLink = { titleKey: string; href: string };
export type NavSection = { sectionKey: string; children: NavLink[] };
export type NavEntry = NavLink | NavSection;

export function isSection(entry: NavEntry): entry is NavSection {
  return "sectionKey" in entry;
}

/** Flatten sections into an ordered list of links (for pager prev/next). */
export function flatNavItems(entries: NavEntry[]): NavLink[] {
  return entries.flatMap((e) => (isSection(e) ? e.children : [e]));
}

export const navItems: NavEntry[] = [
  { titleKey: "gettingStarted", href: "/docs/getting-started" },
  { titleKey: "concepts", href: "/docs/concepts" },
  { titleKey: "configuration", href: "/docs/configuration" },
  { titleKey: "customCommands", href: "/docs/custom-commands" },
  { titleKey: "keyboardShortcuts", href: "/docs/keyboard-shortcuts" },
  { titleKey: "apiReference", href: "/docs/api" },
  { titleKey: "browserAutomation", href: "/docs/browser-automation" },
  { titleKey: "notifications", href: "/docs/notifications" },
  { titleKey: "ssh", href: "/docs/ssh" },
  {
    sectionKey: "agentIntegrations",
    children: [
      { titleKey: "claudeCodeTeams", href: "/docs/agent-integrations/claude-code-teams" },
      { titleKey: "ohMyOpenCode", href: "/docs/agent-integrations/oh-my-opencode" },
      { titleKey: "ohMyCodex", href: "/docs/agent-integrations/oh-my-codex" },
      { titleKey: "ohMyClaudeCode", href: "/docs/agent-integrations/oh-my-claudecode" },
    ],
  },
  { titleKey: "changelog", href: "/docs/changelog" },
];
