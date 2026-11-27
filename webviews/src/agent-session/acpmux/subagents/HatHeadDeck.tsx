// The composer hat's marks (hatHeader.experiment.ts `strip` and `cards`, hatLine.experiment.ts): one
// mark per running line, in the header's icon slot or after the one line's words: its harness's
// (Claude, Codex, ...), a started chat's, or a command's terminal. A click on a mark opens its line and
// stops there, so it never also folds the hat. Pointing at one changes nothing: the header's words
// stay the summary (Leo, 2026-11-27, on the hover that swapped them for that line's title and latest
// step: "tdont think we should have this hover anymore it's really bad").
//
// The marks are pointer twins of the list's lines (aria-hidden): the header button stays the one
// keyboard control, and the open list reaches each line, as the stacked marks do today.
import type { CSSProperties } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { AgentIdentity } from "./AgentIdentity";
import { SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { agentTone } from "./agentTones";
import { SILENT_TURN_ICON, trayItemKey, type TrayItem } from "./runningTray";

const ROW_ICON = rowIconSize(12);

/// The most marks the deck draws; the rest are "+N more", which opens the hat like the header does.
export const DECK_MARKS = 8;

type Mark = { harness?: string; tone?: number; icon: string };

/// A line's mark, as its line draws it (SubagentTray.tsx `stackMarks`), one per line here: each
/// command its own terminal, so each can be named and opened.
function markOf(item: TrayItem, chatHarness: string | undefined): Mark {
  if (item.kind === "agent")
    return { harness: item.agent.harness ?? chatHarness, tone: agentTone(item.agent.id), icon: SUBAGENT_FALLBACK };
  if (item.kind === "session")
    return { harness: item.session.harness, tone: agentTone(item.session.sessionId), icon: "agent.chat" };
  if (item.kind === "turn") return { icon: SILENT_TURN_ICON };
  return { icon: "terminal" };
}

export function HatHeadDeck({
  items,
  chatHarness,
  look,
  at = "lead",
  onOpenItem,
}: {
  /// What runs, in the header's order (trayHeadOrder.ts, longest-running first).
  items: readonly TrayItem[];
  chatHarness: string | undefined;
  look: "strip" | "cards";
  /// Where it sits in the row: leading the words in the icon column, or after them (the one-line hat's
  /// `trail` arm, hatLine.experiment.ts).
  at?: "lead" | "trail";
  onOpenItem: (item: TrayItem) => void;
}) {
  const t = useT();
  const shown = items.slice(0, DECK_MARKS);
  const rest = items.length - shown.length;
  // After the one line's words (`trail`) the deck keeps all DECK_MARKS slots, empty ones too, so "+N
  // more" sits in one place however many lines run and the bar never re-lays out as lines come and go.
  const blanks = at === "trail" ? DECK_MARKS - shown.length : 0;
  return (
    <span className="acpmux-hat-deck" data-look={look} data-at={at} aria-hidden="true">
      {shown.map((item, index) => {
        const key = trayItemKey(item);
        const mark = markOf(item, chatHarness);
        return (
          <span
            key={key}
            className="acpmux-hat-deck__mark"
            aria-hidden="true"
            data-deck-key={key}
            // The deck's order: the first card on top, each later one tucked under it.
            style={{ "--acpmux-deck-index": index, zIndex: shown.length - index } as CSSProperties}
            onClick={(event) => {
              event.stopPropagation();
              onOpenItem(item);
            }}
          >
            <span className="acpmux-hat-deck__face">
              {mark.harness !== undefined || mark.tone !== undefined ? (
                <AgentIdentity
                  harness={mark.harness}
                  tone={mark.tone}
                  size={ROW_ICON}
                  fallback={mark.icon}
                  plain
                  blankUnknown
                />
              ) : (
                <Icon name={mark.icon} size={ROW_ICON} row />
              )}
            </span>
          </span>
        );
      })}
      {Array.from({ length: blanks }, (_, index) => (
        <span key={`blank-${index}`} className="acpmux-hat-deck__mark" data-blank aria-hidden="true">
          <span className="acpmux-hat-deck__face" style={{ width: ROW_ICON, height: ROW_ICON }} />
        </span>
      ))}
      {rest > 0 && <span className="acpmux-summary-meta acpmux-hat-deck__rest">{t("tools.more", { n: rest })}</span>}
    </span>
  );
}
