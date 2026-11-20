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
import { Button } from "../../../ui/Button";
import "../../../ui/controls.css";

import "./sessionInfo.css";
import "./ContextSection.css";
import { type ContextPart, contextParts, type Breakdown, contextBreakdown } from "./contextSectionModel";
const LIST_LABEL = {
  mcpTools: "sessionInfo.context.mcpTools",
  memoryFiles: "sessionInfo.context.memoryFiles",
  skills: "sessionInfo.context.skills",
} as const;

/// The breakdown's bar, its rows and its folds, as Session Info and the ring's details draw them.
/// Without `bar`, its rows and folds alone (Session Info's Context fold: its head has the meter).
export function ContextBreakdownView({ breakdown, bar = true }: { breakdown: Breakdown; bar?: boolean }) {
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
      {bar && (
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
      )}
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
            <Icon name={open.has(list.id) ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
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
  onViewPrompt,
  rowsOnly = false,
}: {
  usage: { used: number; size: number };
  percent: number;
  /// Claude Code's /context, as acpmux kept it (`summary.contextBreakdown`).
  breakdown?: unknown;
  /// Its rows alone, from the first one down (Messages, or Used): Session Info's Context fold, whose
  /// head has the total and the meter (Lucas, 2026-11-06: "the expansion should show the messages and
  /// below").
  rowsOnly?: boolean;
  /// Sends the chat's agent its `/compact` (App.tsx `compactChat`); unset where the agent lists no
  /// compact command or the chat cannot be sent to, so no Compact shows.
  onCompact?: () => void;
  /// Opens the Context screen: every part of the prompt, and the guidance new chats get, editable
  /// (App.tsx `openContext`); unset for a chat whose prompt text acpmux does not hand this pane.
  onViewPrompt?: () => void;
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
      {!rowsOnly && (
        <div className="acpmux-session-info-context__total">
          <span>{t("context.percent", { percent })}</span>
          <span className="acpmux-session-info-context__tokens">
            {tokens.format(usage.used)} / {tokens.format(usage.size)}
          </span>
        </div>
      )}
      {breakdown ? (
        <ContextBreakdownView breakdown={breakdown} bar={!rowsOnly} />
      ) : (
        <>
          {!rowsOnly && (
            <div className="acpmux-session-info-context__bar" aria-hidden="true">
              {parts
                .filter((part) => part.id !== "free" && part.share > 0)
                .map((part) => (
                  <span key={part.id} data-part={part.id} style={{ width: `${part.share * 100}%` }} />
                ))}
            </div>
          )}
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
      {(onCompact || onViewPrompt) && (
        <div className="acpmux-session-info-context__actions">
          {onCompact && free && (
            <span className="acpmux-session-info-context__until">
              {t("sessionInfo.context.untilAutoCompact", { tokens: tokens.format(free.tokens) })}
            </span>
          )}
          {onViewPrompt && (
            <Button size="sm" variant="subtle" data-context-view-prompt onClick={onViewPrompt}>
              {t("contextScreen.viewPrompt")}
            </Button>
          )}
          {onCompact && (
            <Button size="sm" variant="subtle" className="acpmux-session-info-context__compact" onClick={onCompact}>
              {t("sessionInfo.context.compactSession")}
            </Button>
          )}
        </div>
      )}
    </div>
  );
}
