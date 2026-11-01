// One running or finished piece of the chat's work on one line: a subagent or a background
// command. The tray above the composer (SubagentTray.tsx) and the summary card's Subagents list
// (summary/SubagentStatusList.tsx) both draw their rows with it, so a subagent looks the same in
// either place (Leo 2026-10-20: one style for the tray, the chip and the popover). Its icon
// (summary.css `.acpmux-lineage__icon`) is in the theme's accent while it runs, never a brand color,
// and carries no corner dot, since the line says its state in words; then its name, a dim detail (what it does now, or its kind), its time and
// its state. A click opens it. With a `card` (Session Info's Subagents) a hover card names it and
// says its state, as Claude Code desktop's session panel does, in place of the plain tooltip.
//
// In the tray a line also says what kind of thing it is before its name (Leo 2026-10-21 on a tray
// line that showed a raw shell line: "is that a command or a subagent?"): "Command" in words, a
// subagent by its own icon, never the word on every line under a header that says it already (Leo,
// 2026-10-29: "why are you saying sub-agent so many fucking times? Like, you can just add the icon
// when it's in here"). A line that opens something ends in a chevron. A line with nothing to open is
// a disabled button with no hover at all (subagents.css).
//
// In the tray a line has one anatomy, after Claude desktop's and Claude Code's subagent rows (Leo,
// 2026-10-31: "why is this still so ass in latest nightly", and earlier "eg a lot of these
// subtitles are bad"): one leading glyph (the spinner while it works, else its own icon or its
// harness's mark), never a second kind glyph beside it; the title; one muted trailing meta (what it
// spent, a state worth reading, its time); the chevron. No agent-type subtitle on the line (the
// tooltip and the hover card keep it). The tray reserves a status-word track beside the time,
// including Running and Done, so every state keeps the same control geometry.
import type { CSSProperties, ReactNode } from "react";
import { AgentMark, knownMark } from "../../shared/AgentMark";
import { Tooltip } from "../../../ui/Tooltip";
import { waveProps } from "../../../ui/wave";
import { Spinner } from "../conversation/icons";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { SubagentStatus } from "../summary/SubagentStatusList";
import type { Subagent } from "./subagentFold";
import { TonedIcon } from "./TonedIcon";
import { useAgentProgress } from "./agentProgressStore";
import { Tick } from "./trayMotion";

const ROW_ICON = rowIconSize(12);

export function AgentLine({
  name,
  detail,
  progress,
  progressAgent,
  status,
  state,
  time,
  icon = "agent.session",
  mark,
  tone,
  iconSize = ROW_ICON,
  depth = 0,
  current = false,
  title,
  label,
  kind,
  kindIcon,
  chevron = false,
  onOpen,
  after,
  card,
  wave,
  working = false,
  expanded,
  trayColumns = false,
  quiet = false,
  progressAt = "below",
}: {
  name: string;
  /// What it does now, or the kind of agent it is; dim after the name.
  detail?: string;
  /// Reported agent counts, warnings and usage; separate from the current action.
  progress?: string;
  progressAgent?: Subagent;
  status: SubagentStatus;
  /// Its state in words ("Running", "Waiting", "Done").
  state: string;
  /// How long it has run, or ran (formatDuration); none when unknown.
  time?: string;
  /// `agent.session` for a subagent, `terminal` for a background command.
  icon?: string;
  /// The harness of an agent of another family (`codex`), whose mark replaces the icon.
  mark?: string;
  /// Its stable color (agentTones.ts `agentTone`), for the icon when no harness mark replaces it, so
  /// lines without a mark still tell apart (Leo, 2026-10-29: "you can just randomize the colors").
  tone?: number;
  iconSize?: number;
  /// How far it sits under the agent that spawned it.
  depth?: number;
  /// The pane shows it now.
  current?: boolean;
  /// A tooltip with what the line cannot show (a subagent's whole task).
  title?: string;
  /// The accessible name, when the visible text is not enough ("Open Reviewer").
  label?: string;
  /// What kind of thing it is, before its name ("Command"); the tray's lines say it.
  kind?: string;
  /// The kind as an icon before its name in place of the word (a subagent's), with `kind` as its
  /// accessible name.
  kindIcon?: string;
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
  /// Use the running tray's fixed trailing columns; other AgentLine consumers keep their flow.
  trayColumns?: boolean;
  /// Its state needs no word on the line (done, or running under the spinner): screen readers
  /// still read it. Tray lines only.
  quiet?: boolean;
  /// Where `progress` sits on a tray line: in the trailing meta before the time (`meta`), or on a
  /// line under the title (`below`, every other consumer's place).
  progressAt?: "meta" | "below";
}) {
  const liveProgress = useAgentProgress(progressAgent);
  progress = liveProgress ?? progress;
  const shimmer = waveProps(wave);
  const brand = mark ? knownMark(mark, mark.split(/[-_/]/)[0]) : undefined;
  const glyph = <TonedIcon name={icon} size={iconSize} tone={tone} row />;
  const button = (
    <button
      type="button"
      className="acpmux-summary-row acpmux-summary-link acpmux-summary-agent acpmux-agent-line__button"
      style={
        depth > 0
          ? trayColumns
            ? ({ "--acpmux-tray-indent": `${Math.min(depth, 3) * 14}px` } as CSSProperties)
            : { paddingLeft: 8 + Math.min(depth, 3) * 14 }
          : undefined
      }
      data-status={status}
      aria-current={current ? "true" : undefined}
      aria-expanded={expanded}
      // A quiet line names its state here too: an aria-label overrides the line's own text, its
      // screen-reader state word included.
      aria-label={
        label ? [label, trayColumns && quiet ? state : undefined, progress].filter(Boolean).join(" · ") : undefined
      }
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
          <AgentMark agent={brand} size={iconSize} fallback={glyph} />
        ) : (
          glyph
        )}
      </span>
      <span className="acpmux-summary-text">
        {kindIcon ? (
          <span className="acpmux-agent-line__kind-icon">
            <Icon name={kindIcon} size={iconSize} title={kind} row />
          </span>
        ) : (
          kind && <span className="acpmux-agent-line__kind">{kind}</span>
        )}
        <span className="acpmux-summary-agent__name">{name}</span>
        {detail && detail !== name && <span className="acpmux-summary-agent__kind">{detail}</span>}
        {progress && trayColumns && progressAt === "meta" && (
          <span className="acpmux-agent-line__stats">{progress}</span>
        )}
        {progress && !(trayColumns && progressAt === "meta") && (
          <span className="acpmux-agent-line__progress">{progress}</span>
        )}
      </span>
      {trayColumns ? (
        <>
          {/* The tray reserves a visible status track for every row. Keeping the word in the same
              track for quiet (Running/Done/Cancelled) rows prevents a missing state from pulling
              the duration toward the title or moving the Stop and chevron columns. */}
          <span className="acpmux-summary-meta acpmux-agent-line__meta" data-tray-status>
            <Tick className="acpmux-summary-agent__state" text={state} />
          </span>
          <span className="acpmux-summary-meta acpmux-agent-line__time" aria-hidden={time === undefined}>
            {time}
          </span>
          {/* Stop's track (the stop slot, outside this button, lies over it), then the chevron's,
              last at the line's end: the column the header's and View all's chevrons end in. */}
          <span className="acpmux-agent-line__stop-track" aria-hidden="true" />
          {chevron && onOpen ? (
            <span className="acpmux-agent-line__chevron" aria-hidden="true">
              <Icon name="disclosure.collapsed" size={ROW_ICON} row />
            </span>
          ) : (
            <span className="acpmux-agent-line__chevron-track" aria-hidden="true" />
          )}
        </>
      ) : (
        <>
          {time !== undefined && <span className="acpmux-summary-meta acpmux-agent-line__time">{time}</span>}
          {/* Running turns to Waiting or Done with a tick, never a jump (trayMotion.tsx). */}
          <Tick className="acpmux-summary-meta acpmux-summary-agent__state" text={state} />
          {chevron && onOpen && (
            <span className="acpmux-agent-line__chevron" aria-hidden="true">
              <Icon name="disclosure.collapsed" size={ROW_ICON} row />
            </span>
          )}
        </>
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
      {trayColumns ? <span className="acpmux-agent-line__stop-slot">{after}</span> : after}
    </div>
  );
}
