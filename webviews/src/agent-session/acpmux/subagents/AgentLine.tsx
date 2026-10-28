// One running or finished piece of the chat's work on one line: a subagent or a background
// command. The tray above the composer (SubagentTray.tsx) and the summary card's Subagents list
// (summary/SubagentStatusList.tsx) both draw their rows with it, so a subagent looks the same in
// either place (Leo 2026-10-20: one style for the tray, the chip and the popover). Its icon
// (summary.css `.acpmux-lineage__icon`) is in the theme's accent while it runs, never a brand color,
// and carries no corner dot, since the line says its state in words; then its name, a dim detail (what it does now, or its kind), its time and
// its state. A click opens it. With a `card` (the Inspector's Subagents) a hover card names it and
// says its state, as Claude Code desktop's session panel does, in place of the plain tooltip.
//
// In the tray a line also says what kind of thing it is before its name, "Command" or "Subagent"
// (Leo 2026-10-21 on a tray line that showed a raw shell line: "is that a command or a
// subagent?"), and a line that opens something ends in a chevron. A line with nothing to open is
// a disabled button with no hover at all (subagents.css).
import type { ReactNode } from "react";
import { AgentMark, knownMark } from "../../shared/AgentMark";
import { Tooltip } from "../../../ui/Tooltip";
import { waveProps } from "../../../ui/wave";
import { Spinner } from "../conversation/icons";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { SubagentStatus } from "../summary/SubagentStatusList";
import { Tick } from "./trayMotion";

const ROW_ICON = rowIconSize(12);

export function AgentLine({
  name,
  detail,
  status,
  state,
  time,
  icon = "agent.session",
  mark,
  iconSize = ROW_ICON,
  depth = 0,
  current = false,
  title,
  label,
  kind,
  chevron = false,
  onOpen,
  after,
  card,
  wave,
  working = false,
  expanded,
}: {
  name: string;
  /// What it does now, or the kind of agent it is; dim after the name.
  detail?: string;
  status: SubagentStatus;
  /// Its state in words ("Running", "Waiting", "Done").
  state: string;
  /// How long it has run, or ran (formatDuration); none when unknown.
  time?: string;
  /// `agent.session` for a subagent, `terminal` for a background command.
  icon?: string;
  /// The harness of an agent of another family (`codex`), whose mark replaces the icon.
  mark?: string;
  iconSize?: number;
  /// How far it sits under the agent that spawned it.
  depth?: number;
  /// The pane shows it now.
  current?: boolean;
  /// A tooltip with what the line cannot show (a subagent's whole task).
  title?: string;
  /// The accessible name, when the visible text is not enough ("Open Reviewer").
  label?: string;
  /// What kind of thing it is, before its name ("Command", "Subagent"); the tray's lines say it.
  kind?: string;
  /// A trailing chevron when a click opens it (the tray's lines).
  chevron?: boolean;
  onOpen?: () => void;
  /// Drawn after the line, outside its button (a running subagent's stop button).
  after?: ReactNode;
  /// The hover card's content (its name, its state, its task); replaces `title`.
  card?: ReactNode;
  /// Its place among the running lines in the one shared running wave (ui/wave.ts); none for a
  /// line that does not run, which stays still.
  wave?: number;
  /// A live command uses the shared spinner, never a breathing dot.
  working?: boolean;
  /// A command row's live-tail disclosure state.
  expanded?: boolean;
}) {
  const shimmer = waveProps(wave);
  const brand = mark ? knownMark(mark, mark.split(/[-_/]/)[0]) : undefined;
  const button = (
    <button
      type="button"
      className="acpmux-summary-row acpmux-summary-link acpmux-summary-agent acpmux-agent-line__button"
      style={depth > 0 ? { paddingLeft: 8 + Math.min(depth, 3) * 14 } : undefined}
      data-status={status}
      aria-current={current ? "true" : undefined}
      aria-expanded={expanded}
      aria-label={label}
      /* tooltip-allow: the line shows the name; the task appears nowhere else */
      title={card ? undefined : title}
      disabled={!onOpen}
      onClick={onOpen}
    >
      <span
        className={shimmer.className ? `acpmux-lineage__icon ${shimmer.className}` : "acpmux-lineage__icon"}
        style={shimmer.style}
        data-state={status}
      >
        {working ? (
          <Spinner size={iconSize} loading />
        ) : brand ? (
          <AgentMark agent={brand} size={iconSize} />
        ) : (
          <Icon name={icon} size={iconSize} row />
        )}
      </span>
      <span className="acpmux-summary-text">
        {kind && <span className="acpmux-agent-line__kind">{kind}</span>}
        <span className="acpmux-summary-agent__name">{name}</span>
        {detail && detail !== name && <span className="acpmux-summary-agent__kind">{detail}</span>}
      </span>
      {time !== undefined && <span className="acpmux-summary-meta acpmux-agent-line__time">{time}</span>}
      {/* Running turns to Waiting or Done with a tick, never a jump (trayMotion.tsx). */}
      <Tick className="acpmux-summary-meta acpmux-summary-agent__state" text={state} />
      {chevron && onOpen && (
        <span className="acpmux-agent-line__chevron" aria-hidden="true">
          <Icon name="disclosure.collapsed" size={12} />
        </span>
      )}
    </button>
  );
  return (
    <div className="acpmux-agent-line" data-status={status}>
      {card ? (
        // tooltip-allow: the hover card says what the line cuts (its whole name, what it does, its task)
        <Tooltip label={card} side="top" className="ui-card acpmux-agent-card__popup">
          {button}
        </Tooltip>
      ) : (
        button
      )}
      {after}
    </div>
  );
}
