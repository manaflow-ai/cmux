// Session Info's Context, open (Claude Code desktop's): "43% used" with the tokens used of the
// window on the right, a bar split by what fills the window, then a row per part with its colored
// square, its tokens and its share of the window. A Claude Code chat's /context breakdown
// (`summary.contextBreakdown`) splits it by category, with the MCP tools, memory files and skills
// it names under folds; without one, the parts are what is used and the free space. The composer's
// context ring draws the same breakdown in its details (ComposerPickers ContextRing). Where the agent
// lists `/compact`, Compact session sends it, with the tokens left until the agent compacts on its
// own beside it (Leo, 2026-10-28: "You don't have the compact session"). It stays live while a turn
// runs: the /compact queues behind the turn, as one typed in the composer would (Leo, 2026-10-31:
// "COMPACT BUTTON LITERALLY DOESN'T EVEN F***IN WORK"; it was disabled while working, and a chat is
// nearly always working).
import { useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxContextBreakdown } from "../model";
import "./sessionInfo.css";
import "./ContextSection.css";

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
/// A breakdown row: `share` is of the window (0 to 1), none for a deferred category, which takes no
/// room until it loads; `tone` picks a used category's color (0 to TONES - 1, largest first).
export type BreakdownRow = { name: string; tokens: number; kind: Kind; share?: number; tone?: number };
export type BreakdownItem = { name: string; detail?: string; tokens: number };
export type Breakdown = {
  rows: BreakdownRow[];
  lists: { id: "mcpTools" | "memoryFiles" | "skills"; items: BreakdownItem[] }[];
};

/// How many colors the used categories cycle through (ContextSection.css `data-tone`).
const TONES = 6;
const KINDS: readonly Kind[] = ["used", "buffer", "deferred", "free"];
const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0);
const named = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
const records = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value) ? value.filter((row) => row !== null && typeof row === "object") : [];
const tail = (path: string) => path.split("/").filter(Boolean).pop() ?? path;

/// The rows and folds a breakdown draws, or none when it is malformed or names no window. Used
/// categories come largest first, then the buffer, the deferred ones and the free space last; each
/// share is of the window, clamped to it. A category without a name or a known kind is dropped.
export function contextBreakdown(value: unknown): Breakdown | undefined {
  if (value === null || typeof value !== "object") return undefined;
  const source = value as Record<string, unknown>;
  const max = count(source.maxTokens);
  if (max <= 0 || !Array.isArray(source.categories)) return undefined;
  const rows = records(source.categories).flatMap((category): BreakdownRow[] => {
    const name = named(category.name);
    const kind = KINDS.find((known) => known === category.kind);
    return name && kind ? [{ name, kind, tokens: count(category.tokens) }] : [];
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

const LIST_LABEL = {
  mcpTools: "sessionInfo.context.mcpTools",
  memoryFiles: "sessionInfo.context.memoryFiles",
  skills: "sessionInfo.context.skills",
} as const;

/// The breakdown's bar, its rows and its folds, as Session Info and the ring's details draw them.
export function ContextBreakdownView({ breakdown }: { breakdown: Breakdown }) {
  const t = useT();
  const [open, setOpen] = useState<ReadonlySet<string>>(new Set());
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const share = new Intl.NumberFormat(undefined, { style: "percent", maximumFractionDigits: 1 });
  const toggle = (id: string) =>
    setOpen((was) => {
      const next = new Set(was);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  return (
    <div className="acpmux-context-breakdown">
      <div className="acpmux-session-info-context__bar" aria-hidden="true">
        {breakdown.rows
          .filter((row) => (row.kind === "used" || row.kind === "buffer") && (row.share ?? 0) > 0)
          .map((row, index) => (
            <span
              key={`${row.name}-${index}`}
              data-kind={row.kind}
              data-tone={row.tone}
              style={{ width: `${(row.share ?? 0) * 100}%` }}
            />
          ))}
      </div>
      <ul className="acpmux-session-info-list">
        {breakdown.rows.map((row, index) => (
          <li key={`${row.name}-${index}`} className="acpmux-session-info-row" data-kind={row.kind}>
            <span
              className="acpmux-session-info-context__swatch"
              data-kind={row.kind}
              data-tone={row.tone}
              aria-hidden="true"
            />
            <span className="acpmux-session-info-row__name">{row.name}</span>
            <span className="acpmux-session-info-row__end acpmux-session-info-context__count">
              {tokens.format(row.tokens)}
            </span>
            <span className="acpmux-session-info-context__share">
              {row.share === undefined ? "—" : share.format(row.share)}
            </span>
          </li>
        ))}
      </ul>
      {breakdown.lists.map((list) => (
        <div key={list.id} data-list={list.id}>
          <button
            type="button"
            className="acpmux-session-info-row acpmux-session-info-row--button acpmux-context-breakdown__fold"
            aria-expanded={open.has(list.id)}
            onClick={() => toggle(list.id)}
          >
            <Icon name={open.has(list.id) ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
            <span className="acpmux-session-info-row__name">{t(LIST_LABEL[list.id])}</span>
            <span className="acpmux-session-info-row__end">{list.items.length}</span>
          </button>
          {open.has(list.id) && (
            <ul className="acpmux-session-info-list acpmux-context-breakdown__items">
              {list.items.map((item, index) => (
                <li key={`${item.name}-${index}`} className="acpmux-session-info-row">
                  <span className="acpmux-session-info-row__name">{item.name}</span>
                  {item.detail && <span className="acpmux-session-info-row__detail">{item.detail}</span>}
                  <span className="acpmux-session-info-row__end">{tokens.format(item.tokens)}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      ))}
    </div>
  );
}

export function ContextSection({
  usage,
  percent,
  breakdown: reported,
  onCompact,
}: {
  usage: { used: number; size: number };
  percent: number;
  /// Claude Code's /context, as acpmux kept it (`summary.contextBreakdown`).
  breakdown?: unknown;
  /// Sends the chat's agent its `/compact` (App.tsx `compactChat`); unset where the agent lists no
  /// compact command or the chat cannot be sent to, so no Compact shows.
  onCompact?: () => void;
}) {
  const t = useT();
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const share = new Intl.NumberFormat(undefined, { style: "percent", maximumFractionDigits: 1 });
  const parts = contextParts(usage);
  const breakdown = contextBreakdown(reported);
  // Claude Code's free space is what is left before its autocompact buffer: the tokens until it
  // compacts on its own. Without a buffer row the harness does not say, so no count shows.
  const free = breakdown?.rows.some((row) => row.kind === "buffer")
    ? breakdown.rows.find((row) => row.kind === "free")
    : undefined;
  const label = (id: ContextPart["id"]) => t(id === "used" ? "sessionInfo.context.used" : "sessionInfo.context.free");
  return (
    <div className="acpmux-session-info-context" data-section="context">
      <div className="acpmux-session-info-context__total">
        <span>{t("context.percent", { percent })}</span>
        <span className="acpmux-session-info-context__tokens">
          {tokens.format(usage.used)} / {tokens.format(usage.size)}
        </span>
      </div>
      {breakdown ? (
        <ContextBreakdownView breakdown={breakdown} />
      ) : (
        <>
          <div className="acpmux-session-info-context__bar" aria-hidden="true">
            {parts
              .filter((part) => part.id !== "free" && part.share > 0)
              .map((part) => (
                <span key={part.id} data-part={part.id} style={{ width: `${part.share * 100}%` }} />
              ))}
          </div>
          <ul className="acpmux-session-info-list">
            {parts.map((part) => (
              <li key={part.id} className="acpmux-session-info-row" data-part={part.id}>
                <span className="acpmux-session-info-context__swatch" data-part={part.id} aria-hidden="true" />
                <span className="acpmux-session-info-row__name">{label(part.id)}</span>
                <span className="acpmux-session-info-row__end acpmux-session-info-context__count">
                  {tokens.format(part.tokens)}
                </span>
                <span className="acpmux-session-info-context__share">{share.format(part.share)}</span>
              </li>
            ))}
          </ul>
        </>
      )}
      {onCompact && (
        <div className="acpmux-session-info-context__actions">
          {free && (
            <span className="acpmux-session-info-context__until">
              {t("sessionInfo.context.untilAutoCompact", { tokens: tokens.format(free.tokens) })}
            </span>
          )}
          <button type="button" className="acpmux-session-info-context__compact" onClick={onCompact}>
            {t("sessionInfo.context.compactSession")}
          </button>
        </div>
      )}
    </div>
  );
}
