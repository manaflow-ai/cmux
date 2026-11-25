import type { AcpmuxContextBreakdown } from "../model";

/// One part of the context window: its tokens and its share of the window (0 to 1).
export type ContextPart = { readonly id: "used" | "free"; readonly tokens: number; readonly share: number };

/// The window's parts, used first, whose shares add up to 1. Usage past the window counts as full.
export function contextParts(usage: { used: number; size: number }): ContextPart[] {
  const size = Math.max(0, usage.size);
  const used = Math.min(size, Math.max(0, usage.used));
  const share = (tokens: number) => (size > 0 ? tokens / size : 0);
  return [
    { id: "used", tokens: used, share: share(used) },
    { id: "free", tokens: size - used, share: share(size - used) },
  ];
}

type Kind = AcpmuxContextBreakdown["categories"][number]["kind"];
/// A used category's color, as Claude Code desktop's Context card colors it (Lucas, 2026-11-23:
/// "make it more identical to claude"): Messages blue, MCP tools orange, System prompt green, Skills
/// yellow, every other used category one grey (ContextSection.css `data-hue`).
export type BreakdownHue = "messages" | "mcpTools" | "systemPrompt" | "skills" | "other";
/// A breakdown row: `share` is of the window (0 to 1), none for a deferred category, which takes no
/// room until it loads; `tone` picks a used category's step for the App's panel (0 to TONES - 1,
/// largest first); `hue` is a used category's color in the page's.
export type BreakdownRow = {
  name: string;
  tokens: number;
  kind: Kind;
  share?: number;
  tone?: number;
  hue?: BreakdownHue;
};
export type BreakdownItem = { name: string; detail?: string; tokens: number };
export type Breakdown = {
  rows: BreakdownRow[];
  lists: { id: "mcpTools" | "memoryFiles" | "skills"; items: BreakdownItem[] }[];
};

/// How many colors the used categories cycle through (ContextSection.css `data-tone`).
const TONES = 6;
/// Claude Code desktop's order: what is used, the autocompact buffer and the free space (which add
/// up to the window), then the deferred categories, which take no room yet.
const KINDS: readonly Kind[] = ["used", "buffer", "free", "deferred"];
/// Claude Code's category ids (or its display names, snake-cased, where it sent no id) to a hue.
const HUES: Readonly<Record<string, BreakdownHue>> = {
  messages: "messages",
  mcp_tools: "mcpTools",
  system_prompt: "systemPrompt",
  skills: "skills",
};
const hueOf = (id: string | undefined, name: string): BreakdownHue =>
  HUES[id ?? name.toLowerCase().replace(/[^a-z]+/g, "_")] ?? "other";
const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0);
const named = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
const records = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value) ? value.filter((row) => row !== null && typeof row === "object") : [];
const tail = (path: string) => path.split("/").filter(Boolean).pop() ?? path;

/// The rows and folds a breakdown draws, or none when it is malformed or names no window. Used
/// categories come largest first, then the buffer, the free space and the deferred ones last; each
/// share is of the window, clamped to it. A category without a name or a known kind is dropped.
export function contextBreakdown(value: unknown): Breakdown | undefined {
  if (value === null || typeof value !== "object") return undefined;
  const source = value as Record<string, unknown>;
  const max = count(source.maxTokens);
  if (max <= 0 || !Array.isArray(source.categories)) return undefined;
  const rows = records(source.categories).flatMap((category): BreakdownRow[] => {
    const name = named(category.name);
    const kind = KINDS.find((known) => known === category.kind);
    if (!name || !kind) return [];
    return [
      {
        name,
        kind,
        tokens: count(category.tokens),
        ...(kind === "used" ? { hue: hueOf(named(category.id), name) } : {}),
      },
    ];
  });
  if (rows.length === 0) return undefined;
  const ordered = KINDS.flatMap((kind) =>
    rows.filter((row) => row.kind === kind).sort((a, b) => (kind === "used" ? b.tokens - a.tokens : 0)),
  ).map((row, index) => ({
    ...row,
    ...(row.kind === "deferred" ? {} : { share: Math.min(1, row.tokens / max) }),
    ...(row.kind === "used" ? { tone: index % TONES } : {}),
  }));
  const items = (list: unknown, name: (row: Record<string, unknown>) => BreakdownItem | undefined) =>
    records(list).flatMap((row) => name(row) ?? []);
  const lists: Breakdown["lists"] = [
    {
      id: "mcpTools" as const,
      items: items(source.mcpTools, (row) => {
        const tool = named(row.name);
        const server = named(row.serverName);
        // Claude Code names an MCP tool `mcp__<server>__<tool>`: its server is the row's detail.
        const short = server && tool?.startsWith(`mcp__${server}__`) ? tool.slice(server.length + 7) : tool;
        return short ? { name: short, detail: server, tokens: count(row.tokens) } : undefined;
      }),
    },
    {
      id: "memoryFiles" as const,
      items: items(source.memoryFiles, (row) => {
        const path = named(row.path);
        return path ? { name: tail(path), detail: path, tokens: count(row.tokens) } : undefined;
      }),
    },
    {
      id: "skills" as const,
      items: items(source.skills, (row) => {
        const skill = named(row.name);
        return skill ? { name: skill, tokens: count(row.tokens) } : undefined;
      }),
    },
  ].filter((list) => list.items.length > 0);
  return { rows: ordered, lists };
}
