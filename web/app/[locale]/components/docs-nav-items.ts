import type { Locale } from "../../../i18n/routing";
import {
  featureWorkflowContentLocales,
  remoteTmuxDocsLocales,
} from "../../../i18n/locale-availability";

export type NavLink = {
  titleKey: string;
  href: string;
  locales?: readonly Locale[];
};
export type NavSection = { sectionKey: string; children: NavLink[] };
export type NavEntry = NavLink | NavSection;

export const baseDocsLocales = ["en"] as const satisfies readonly Locale[];

export function isSection(entry: NavEntry): entry is NavSection {
  return "sectionKey" in entry;
}

/** Flatten sections into an ordered list of links (for pager prev/next). */
export function flatNavItems(entries: NavEntry[]): NavLink[] {
  return entries.flatMap((e) => (isSection(e) ? e.children : [e]));
}

function isLinkVisible(item: NavLink, locale: string): boolean {
  return !item.locales || item.locales.includes(locale as Locale);
}

export function navItemsForLocale(locale: string): NavEntry[] {
  const entries: NavEntry[] = [];
  for (const entry of navItems) {
    if (!isSection(entry)) {
      if (isLinkVisible(entry, locale)) entries.push(entry);
      continue;
    }
    const children = entry.children.filter((child) =>
      isLinkVisible(child, locale)
    );
    if (children.length > 0) entries.push({ ...entry, children });
  }
  return entries;
}

export const navItems: NavEntry[] = [
  { titleKey: "gettingStarted", href: "/docs/getting-started" },
  { titleKey: "concepts", href: "/docs/concepts" },
  { titleKey: "base", href: "/docs/base", locales: baseDocsLocales },
  { titleKey: "workspaceGroups", href: "/docs/workspace-groups" },
  { titleKey: "configuration", href: "/docs/configuration" },
  { titleKey: "textBox", href: "/docs/textbox" },
  { titleKey: "sessionRestore", href: "/docs/session-restore" },
  { titleKey: "vault", href: "/docs/vault", locales: featureWorkflowContentLocales },
  { titleKey: "taskManager", href: "/docs/task-manager", locales: featureWorkflowContentLocales },
  { titleKey: "customCommands", href: "/docs/custom-commands" },
  { titleKey: "dock", href: "/docs/dock" },
  { titleKey: "keyboardShortcuts", href: "/docs/keyboard-shortcuts" },
  { titleKey: "apiReference", href: "/docs/api" },
  { titleKey: "browserAutomation", href: "/docs/browser-automation" },
  { titleKey: "skills", href: "/docs/skills" },
  { titleKey: "notifications", href: "/docs/notifications" },
  { titleKey: "ssh", href: "/docs/ssh" },
  { titleKey: "ios", href: "/docs/ios" },
  { titleKey: "remoteTmux", href: "/docs/remote-tmux", locales: remoteTmuxDocsLocales },
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
