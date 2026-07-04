import type { MetadataRoute } from "next";
import { featureWorkflowContentLocales } from "../i18n/locale-availability";
import { locales } from "../i18n/routing";

export default function sitemap(): MetadataRoute.Sitemap {
  const base = "https://cmux.com";

  const paths: Array<{
    path: string;
    lastModified: string;
    changeFrequency: MetadataRoute.Sitemap[number]["changeFrequency"];
    priority: number;
    locales?: readonly string[];
  }> = [
    { path: "", lastModified: "2026-03-18", changeFrequency: "weekly" as const, priority: 1 },
    { path: "/ios", lastModified: "2026-06-22", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/pricing", lastModified: "2026-07-01", changeFrequency: "monthly" as const, priority: 0.9 },
    { path: "/blog", lastModified: "2026-06-23", changeFrequency: "weekly" as const, priority: 0.8 },
    { path: "/blog/cmux-home", lastModified: "2026-06-23", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmux-history", lastModified: "2026-06-02", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmux-finder", lastModified: "2026-05-22", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmux-vault", lastModified: "2026-07-03", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/passkey-auth", lastModified: "2026-05-22", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/task-manager", lastModified: "2026-07-03", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/markdown-viewer", lastModified: "2026-05-22", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/unread-shortcuts", lastModified: "2026-05-22", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/session-restore", lastModified: "2026-07-03", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/show-hn-launch", lastModified: "2026-02-21", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/introducing-cmux", lastModified: "2026-02-12", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/zen-of-cmux", lastModified: "2026-02-27", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmux-claude-teams", lastModified: "2026-03-30", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmux-omo", lastModified: "2026-03-30", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmux-ssh", lastModified: "2026-07-03", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/gpl", lastModified: "2026-03-30", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/blog/cmd-shift-u", lastModified: "2026-03-04", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/getting-started", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.9 },
    { path: "/docs/concepts", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/workspace-groups", lastModified: "2026-06-09", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/configuration", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/textbox", lastModified: "2026-05-26", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/session-restore", lastModified: "2026-07-03", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/vault", lastModified: "2026-07-03", changeFrequency: "monthly" as const, priority: 0.7, locales: featureWorkflowContentLocales },
    { path: "/docs/task-manager", lastModified: "2026-07-03", changeFrequency: "monthly" as const, priority: 0.7, locales: featureWorkflowContentLocales },
    { path: "/docs/custom-commands", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/dock", lastModified: "2026-05-01", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/keyboard-shortcuts", lastModified: "2026-04-03", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/api", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/browser-automation", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/skills", lastModified: "2026-05-15", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/notifications", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/ssh", lastModified: "2026-07-03", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/ios", lastModified: "2026-06-21", changeFrequency: "monthly" as const, priority: 0.8 },
    { path: "/docs/agent-integrations/claude-code-teams", lastModified: "2026-03-30", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/agent-integrations/oh-my-opencode", lastModified: "2026-03-30", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/agent-integrations/oh-my-codex", lastModified: "2026-03-30", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/agent-integrations/oh-my-claudecode", lastModified: "2026-03-30", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/docs/changelog", lastModified: "2026-03-18", changeFrequency: "weekly" as const, priority: 0.5 },
    { path: "/community", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.5 },
    { path: "/wall-of-love", lastModified: "2026-03-18", changeFrequency: "monthly" as const, priority: 0.5 },
    { path: "/nightly", lastModified: "2026-03-18", changeFrequency: "weekly" as const, priority: 0.6 },
    { path: "/assets", lastModified: "2026-06-03", changeFrequency: "monthly" as const, priority: 0.5 },
    // SEO landing/guide pages: localized, not in the main nav.
    { path: "/guides", lastModified: "2026-06-22", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/best-terminal-for-mac", lastModified: "2026-06-22", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/built-on-ghostty", lastModified: "2026-06-22", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/agents", lastModified: "2026-06-23", changeFrequency: "monthly" as const, priority: 0.7 },
    { path: "/agents/claude-code", lastModified: "2026-06-22", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/agents/codex", lastModified: "2026-06-22", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/agents/opencode", lastModified: "2026-06-22", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/agents/gemini-cli", lastModified: "2026-06-23", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/agents/aider", lastModified: "2026-06-23", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/agents/amp", lastModified: "2026-06-23", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/agents/cursor-cli", lastModified: "2026-06-23", changeFrequency: "monthly" as const, priority: 0.6 },
    { path: "/privacy-policy", lastModified: "2026-03-18", changeFrequency: "yearly" as const, priority: 0.3 },
    { path: "/terms-of-service", lastModified: "2026-03-18", changeFrequency: "yearly" as const, priority: 0.3 },
    { path: "/eula", lastModified: "2026-03-18", changeFrequency: "yearly" as const, priority: 0.3 },
  ];

  // Legal pages are English-only (not translated), so they only get one entry.
  // The SEO landing pages are localized, so they go through the per-locale loop.
  const englishOnly = new Set(["/privacy-policy", "/terms-of-service", "/eula"]);

  const entries: MetadataRoute.Sitemap = [];

  for (const { path, lastModified, changeFrequency, priority, locales: pathLocales } of paths) {
    if (englishOnly.has(path)) {
      entries.push({
        url: `${base}${path}`,
        lastModified,
        changeFrequency,
        priority,
      });
      continue;
    }

    const availableLocales = pathLocales ?? locales;
    const alternates: Record<string, string> = {};
    for (const locale of availableLocales) {
      alternates[locale] =
        locale === "en" ? `${base}${path}` : `${base}/${locale}${path}`;
    }
    alternates["x-default"] = `${base}${path}`;

    // Emit a separate entry for each locale so Google sees every URL declared
    for (const locale of availableLocales) {
      const url =
        locale === "en" ? `${base}${path}` : `${base}/${locale}${path}`;
      entries.push({
        url,
        lastModified,
        changeFrequency,
        priority,
        alternates: { languages: alternates },
      });
    }
  }

  return entries;
}
