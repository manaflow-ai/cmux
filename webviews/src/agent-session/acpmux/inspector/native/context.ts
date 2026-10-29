// Session Info's Context, drawn by the App (ChatInspector's `context`, ContextSection.tsx): the share
// of the window used beside the title with its meter, then the window's total and a row per part
// (Claude Code's /context breakdown when acpmux kept one, else used and free). A subagent's panel
// with no usage shows what it has spent (subagentProgress) as the title's value alone.
import type { PaneLanguage, Translate } from "../../i18n";
import type { Subagent } from "../../subagents/subagentFold";
import { subagentProgress } from "../../subagents/subagentProgress";
import { contextBreakdown, contextParts } from "../ContextSection";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection } from "./model";

export const CONTEXT_SYMBOL = "gauge.with.dots.needle.33percent";

const LIST_LABEL = {
  mcpTools: "chatInspector.context.mcpTools",
  memoryFiles: "chatInspector.context.memoryFiles",
  skills: "chatInspector.context.skills",
} as const;

export type ContextInput = {
  /// `summary.usage`.
  usage?: { used: number; size: number };
  /// Claude Code's /context, as acpmux kept it (`summary.contextBreakdown`).
  breakdown?: unknown;
  /// The subagent this panel lists: its progress stands in when no usage is known.
  agent?: Subagent;
  language: PaneLanguage;
  /// The section is unfolded (`sections.context`).
  open: boolean;
  /// The breakdown's folds that are open (ContextBreakdownView's own state, held by the caller).
  openLists?: ReadonlySet<string>;
  /// Opens or closes one of the breakdown's folds; without it the folds show their counts only.
  onToggleList?: (id: "mcpTools" | "memoryFiles" | "skills") => void;
};

export function contextSection(
  input: ContextInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { usage } = input;
  const base = { id: "context", group: "about", title: t("rail.context"), symbol: CONTEXT_SYMBOL } as const;
  if (usage === undefined || usage.size <= 0) {
    const progress = input.agent ? subagentProgress(t, input.language, input.agent) : [];
    if (progress.length === 0) return undefined;
    return { ...base, meta: progress.join(" · "), open: true, foldable: false, rows: [] };
  }
  // As the composer's context ring reads it (ComposerPickers ContextRing).
  const fraction = Math.min(1, Math.max(0, usage.used / usage.size));
  const percent = Math.round(fraction * 100);
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const share = new Intl.NumberFormat(undefined, { style: "percent", maximumFractionDigits: 1 });
  const rows: NativeInfoRow[] = [
    {
      id: "total",
      title: t("context.percent", { percent }),
      trailing: `${tokens.format(usage.used)} / ${tokens.format(usage.size)}`,
    },
  ];
  const breakdown = contextBreakdown(input.breakdown);
  if (breakdown) {
    breakdown.rows.forEach((row, index) => {
      const drawn = (row.kind === "used" || row.kind === "buffer") && (row.share ?? 0) > 0;
      rows.push({
        id: `category:${index}:${row.name}`,
        title: row.name,
        trailing: `${tokens.format(row.tokens)} · ${row.share === undefined ? "—" : share.format(row.share)}`,
        tone: row.kind === "used" ? undefined : "muted",
        ...(drawn ? { meter: row.share } : {}),
      });
    });
    for (const list of breakdown.lists) {
      const open = input.openLists?.has(list.id) === true;
      const toggle = input.onToggleList;
      rows.push({
        id: `list:${list.id}`,
        symbol: open ? "chevron.down" : "chevron.right",
        title: t(LIST_LABEL[list.id]),
        trailing: String(list.items.length),
        ...(toggle ? { action: actions.add(`context.toggle:${list.id}`, () => toggle(list.id)) } : {}),
      });
      if (open)
        list.items.forEach((item, index) =>
          rows.push({
            id: `list:${list.id}:${index}:${item.name}`,
            title: item.name,
            ...(item.detail ? { detail: item.detail, help: item.detail } : {}),
            trailing: tokens.format(item.tokens),
            indent: 1,
          }),
        );
    }
  } else {
    for (const part of contextParts(usage))
      rows.push({
        id: part.id,
        title: t(part.id === "used" ? "chatInspector.context.used" : "chatInspector.context.free"),
        trailing: `${tokens.format(part.tokens)} · ${share.format(part.share)}`,
        ...(part.id === "used" ? { meter: part.share } : { tone: "muted" as const }),
      });
  }
  return {
    ...base,
    meta: t("rail.percent", { percent }),
    meter: percent / 100,
    open: input.open,
    foldable: true,
    rows,
  };
}
