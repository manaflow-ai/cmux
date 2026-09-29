import type { Locale } from "@/i18n/routing";
import {
  docsPathAvailableInChannel,
  type DocsChannel,
} from "@/app/lib/docs-channel";
import {
  fallbackContentLocales,
  featureWorkflowContentLocales,
  managedPoliciesDocsLocales,
  remoteTmuxDocsLocales,
} from "../../../i18n/locale-availability";

/**
 * One docs page in the sidebar. `locales` limits which UI locales list the
 * page at all; `contentLocales` lists the locales that have translated body
 * text (others fall back, see `navItemContentLocale`).
 */
export interface NavLink {
  titleKey: string;
  href: string;
  locales?: readonly Locale[];
  contentLocales?: readonly Locale[];
}
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

function isLinkVisible(item: NavLink, locale: string, channel: DocsChannel): boolean {
  return docsPathAvailableInChannel(channel, item.href)
    && (!item.locales || item.locales.includes(locale as Locale));
}

export function navItemsForLocale(
  locale: string,
  channel: DocsChannel = "release",
): NavEntry[] {
  const visible = (link: NavLink) => isLinkVisible(link, locale, channel);
  // Drop hidden links, and drop a whole section once none of its links remain.
  return navItems.flatMap((entry): NavEntry[] => {
    if (!isSection(entry)) return visible(entry) ? [entry] : [];
    const shown = entry.children.filter(visible);
    return shown.length === 0 ? [] : [{ sectionKey: entry.sectionKey, children: shown }];
  });
}

export function navItemContentLocale(item: NavLink, locale: string): Locale {
  const requestedLocale = locale as Locale;
  if (!item.contentLocales || item.contentLocales.includes(requestedLocale)) {
    return requestedLocale;
  }
  return item.contentLocales[0];
}

export function hasNavItemContent(item: NavLink, locale: string): boolean {
  return navItemContentLocale(item, locale) === locale;
}

export const navItems: NavEntry[] = [
  {
    sectionKey: "basicsSection",
    children: [
      { titleKey: "gettingStarted", href: "/docs/getting-started" },
      { titleKey: "concepts", href: "/docs/concepts" },
      { titleKey: "keyboardShortcuts", href: "/docs/keyboard-shortcuts" },
    ],
  },
  {
    sectionKey: "workspacesSection",
    children: [
      { titleKey: "workspaceGroups", href: "/docs/workspace-groups" },
      { titleKey: "sessionRestore", href: "/docs/session-restore" },
      { titleKey: "textBox", href: "/docs/textbox" },
      { titleKey: "dock", href: "/docs/dock" },
      { titleKey: "taskManager", href: "/docs/task-manager", locales: featureWorkflowContentLocales },
    ],
  },
  {
    sectionKey: "agentsSection",
    children: [
      { titleKey: "notifications", href: "/docs/notifications" },
      { titleKey: "skills", href: "/docs/skills" },
      { titleKey: "vault", href: "/docs/vault", locales: featureWorkflowContentLocales },
      { titleKey: "claudeCodeTeams", href: "/docs/agent-integrations/claude-code-teams" },
      { titleKey: "ohMyOpenCode", href: "/docs/agent-integrations/oh-my-opencode" },
      { titleKey: "ohMyCodex", href: "/docs/agent-integrations/oh-my-codex" },
      {
        titleKey: "ohMyPi",
        href: "/docs/agent-integrations/oh-my-pi",
        contentLocales: fallbackContentLocales,
      },
      { titleKey: "ohMyClaudeCode", href: "/docs/agent-integrations/oh-my-claudecode" },
    ],
  },
  {
    sectionKey: "automationSection",
    children: [
      { titleKey: "apiReference", href: "/docs/api" },
      { titleKey: "browserAutomation", href: "/docs/browser-automation" },
      { titleKey: "computerUse", href: "/docs/computer-use" },
    ],
  },
  {
    sectionKey: "remoteSection",
    children: [
      { titleKey: "ssh", href: "/docs/ssh" },
      {
        titleKey: "remoteTmux",
        href: "/docs/remote-tmux",
        locales: remoteTmuxDocsLocales,
      },
      {
        titleKey: "tui",
        href: "/docs/tui",
        locales: fallbackContentLocales,
        contentLocales: fallbackContentLocales,
      },
      { titleKey: "ios", href: "/docs/ios" },
    ],
  },
  {
    sectionKey: "cloudSection",
    children: [
      { titleKey: "cloudOverview", href: "/docs/cloud" },
      { titleKey: "base", href: "/docs/base", locales: baseDocsLocales },
      { titleKey: "cloudMachines", href: "/docs/cloud/machines" },
      { titleKey: "cloudWorkspaces", href: "/docs/cloud/workspaces" },
      { titleKey: "cloudNetworking", href: "/docs/cloud/networking" },
      { titleKey: "cloudCli", href: "/docs/cloud/cli" },
      { titleKey: "cloudTroubleshooting", href: "/docs/cloud/troubleshooting" },
    ],
  },
  {
    sectionKey: "customizeSection",
    children: [
      { titleKey: "configuration", href: "/docs/configuration" },
      { titleKey: "customCommands", href: "/docs/custom-commands" },
      {
        titleKey: "managedPolicies",
        href: "/docs/managed-policies",
        locales: managedPoliciesDocsLocales,
        contentLocales: managedPoliciesDocsLocales,
      },
    ],
  },
  { titleKey: "changelog", href: "/docs/changelog" },
];
