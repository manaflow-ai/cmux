import { safeHref } from "../replyHref";

export type SummaryProvenance = "builtin" | "user" | "agent";
export type SummaryIcon = "file" | "folder" | "link" | "task" | "warning" | "source" | "change" | "agent";
export type SummaryRow = {
  title: string;
  subtitle?: string;
  icon?: SummaryIcon;
  href?: string;
  badge?: string;
  state?: string;
  provenance: SummaryProvenance;
};
export type SummarySectionInput = {
  id: string;
  title: string;
  order?: number;
  hidden?: boolean;
  provider?: "builtin" | "command" | "file" | "mcp";
  rows: readonly SummaryRow[];
};

const ICONS = new Set<SummaryIcon>(["file", "folder", "link", "task", "warning", "source", "change", "agent"]);
const LIMITS = { title: 160, subtitle: 240, badge: 32 } as const;

function text(value: unknown, limit: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, limit) : undefined;
}

function insideChatFolder(href: string, cwd: string): boolean {
  if (!href.startsWith("/") || /%2e|%2f|%5c/i.test(href)) return false;
  const normalize = (value: string) => {
    const parts: string[] = [];
    for (const part of value.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") parts.pop();
      else parts.push(part);
    }
    return `/${parts.join("/")}`;
  };
  const root = normalize(cwd).replace(/\/$/, "") || "/";
  const path = normalize(href);
  return path === root || path.startsWith(`${root}/`);
}

function href(value: unknown, provenance: SummaryProvenance, cwd: string): string | undefined {
  if (typeof value !== "string") return undefined;
  const raw = value.trim();
  if (!raw) return undefined;
  if (insideChatFolder(raw, cwd)) return raw;
  if (/^cmux:\/\/[a-z0-9][a-z0-9._/-]*$/i.test(raw)) return raw;
  const web = safeHref(raw);
  return web && provenance !== "agent" ? web : web && provenance === "agent" ? web : undefined;
}

export function sanitizeSummaryRows(
  rows: readonly SummaryRow[],
  provenance: SummaryProvenance,
  cwd: string,
): SummaryRow[] {
  return rows.slice(0, 50).flatMap((row) => {
    const title = text(row?.title, LIMITS.title);
    if (!title) return [];
    const rowProvenance = row.provenance ?? provenance;
    const next: SummaryRow = {
      title,
      provenance: rowProvenance,
      subtitle: text(row.subtitle, LIMITS.subtitle),
      badge: text(row.badge, LIMITS.badge),
      state: text(row.state, 32),
      icon: ICONS.has(row.icon as SummaryIcon) ? row.icon : undefined,
      href: href(row.href, rowProvenance, cwd),
    };
    return [next];
  });
}

export function sanitizeSections(sections: readonly SummarySectionInput[], cwd: string): SummarySectionInput[] {
  return sections
    .filter((section) => !section.hidden && text(section.id, 64) && text(section.title, 100))
    .sort((a, b) => (a.order ?? 0) - (b.order ?? 0))
    .map((section) => ({
      ...section,
      id: text(section.id, 64)!,
      title: text(section.title, 100)!,
      rows: sanitizeSummaryRows(section.rows, section.provider === "builtin" ? "builtin" : "user", cwd),
    }));
}
