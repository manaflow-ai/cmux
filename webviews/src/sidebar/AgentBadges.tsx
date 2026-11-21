// l10n-allow-file: gallery design fixtures for the native agent badges (experiments.agentBadges), not shipped UI.
// Leo, 2026-11-19: "Count and status badges on tabs and sidebar rows. Neutral count pill for unread
// agent messages or pending approvals, width reserved so tabs never shift; sidebar rows get one
// tinted status pill (Running, Needs approval, Done); variant: a thin light beam travels along the
// row edge while an agent runs. Switch experiments.agentBadges."
// The native app draws these in AppKit (AgentBadgesExperiment.swift); this is a web mock of that
// look so the arms can be rated side by side. Patterns it follows: grey counter pills beside tab
// labels, one small tinted pill on an otherwise identical row, and a short gradient light segment
// running along a card's border.
// Zero shift: each slot stacks every text it can show (AgentBadgesModel.ts sizers) invisibly in one
// grid cell, so its width is the widest text's in the real font, whatever the state.
import type { CSSProperties } from "react";
import { AgentMark } from "../agent-session/shared/AgentMark";
import { Spinner } from "../agent-session/acpmux/conversation/icons";
import { STATUS_UNREAD } from "../theme/statusColors";
import {
  countSlot,
  pillSlot,
  showsBeam,
  STATUS_SPOKEN,
  tabCount,
  type AgentStatus,
  type BadgeLook,
  type Slot,
} from "./AgentBadgesModel";
import "./AgentBadges.css";

export interface BadgeTab {
  title: string;
  harness: string;
  unread: number;
  approvals: number;
  selected?: boolean;
}

export interface BadgeRow {
  title: string;
  harness: string;
  status: AgentStatus;
  selected?: boolean;
}

export interface TimelineFrame {
  label: string;
  tab: BadgeTab;
  row: BadgeRow;
}

export interface AgentBadgesProps {
  look: BadgeLook;
  tabs?: BadgeTab[];
  rows?: BadgeRow[];
  /** Frames of one tab and one row stepping through states, side by side, with a guide on each title's trailing edge. */
  timeline?: TimelineFrame[];
}

const rootStyle = { "--abg-blue-fallback": STATUS_UNREAD } as CSSProperties;

/** A slot as wide as its widest text in every state: the sizers hold the width, the text shows. */
function Reserved({ slot, className, tone }: { slot: Slot; className: string; tone?: string }) {
  return (
    <span className={`abg-slot ${className}`} data-empty={slot.text ? undefined : true} data-tone={tone}>
      {slot.sizers.map((text) => (
        <span key={text} className="abg-sizer" aria-hidden>
          {text}
        </span>
      ))}
      <span className="abg-face">{slot.text}</span>
    </span>
  );
}

function TabCount({ look, tab }: { look: BadgeLook; tab: BadgeTab }) {
  const count = tabCount(tab.unread, tab.approvals);
  if (look === "off") {
    // Today: an unread dot, no number, in the tab's trailing slot.
    return <span className="abg-tab-trail">{count > 0 && <span className="abg-dot" data-tone="blue" />}</span>;
  }
  return <Reserved slot={countSlot(count)} className={look === "dot-count" ? "abg-countdot" : "abg-count"} />;
}

function Tab({ look, tab }: { look: BadgeLook; tab: BadgeTab }) {
  const count = tabCount(tab.unread, tab.approvals);
  return (
    <div
      className="abg-tab"
      data-selected={tab.selected || undefined}
      data-gallery-track
      aria-label={count > 0 ? `${tab.title}, ${count} new` : tab.title}
    >
      <AgentMark agent={tab.harness} size={14} reserve />
      <span className="abg-tab-title">{tab.title}</span>
      <TabCount look={look} tab={tab} />
    </div>
  );
}

function OffMark({ status }: { status: AgentStatus }) {
  if (status === "running") return <Spinner size={14} />;
  if (status === "approval") return <span className="abg-dot" data-tone="yellow" />;
  if (status === "done") return <span className="abg-dot" data-tone="blue" />;
  return null;
}

/** The light that runs along a running row's rounded edge: three dashes of one path (tail, body, head). */
function Beam() {
  return (
    <svg className="abg-beam" aria-hidden>
      {(["tail", "body", "head"] as const).map((part) => (
        // The attributes are the fallback; CSS geometry insets the rect by half the stroke where supported.
        <rect
          key={part}
          className="abg-beam-seg"
          data-part={part}
          width="100%"
          height="100%"
          pathLength={100}
          rx={7.25}
        />
      ))}
    </svg>
  );
}

function Row({ look, row }: { look: BadgeLook; row: BadgeRow }) {
  return (
    <div
      className="abg-row"
      data-row-id={row.title}
      data-status={row.status}
      aria-selected={row.selected || undefined}
      aria-label={`${row.title}${STATUS_SPOKEN[row.status]}`}
    >
      {showsBeam(look, row.status) && <Beam />}
      <span className="abg-lead">
        <AgentMark agent={row.harness} size={16} reserve />
      </span>
      <span className="abg-title">{row.title}</span>
      {look === "off" ? (
        <span className="abg-trail">
          <OffMark status={row.status} />
        </span>
      ) : (
        <Reserved slot={pillSlot(row.status)} className="abg-pill" tone={row.status} />
      )}
    </div>
  );
}

export function AgentBadges({ look, tabs = [], rows = [], timeline }: AgentBadgesProps) {
  if (timeline) {
    return (
      <div className="abg-root abg-timeline" data-look={look} style={rootStyle}>
        {timeline.map((frame, index) => (
          <figure key={frame.label} className="abg-frame">
            <figcaption className="abg-caption">
              {index + 1}. {frame.label}
            </figcaption>
            <div className="abg-strip" data-guide>
              <Tab look={look} tab={frame.tab} />
            </div>
            <div className="abg-sidebar" data-guide>
              <Row look={look} row={frame.row} />
            </div>
          </figure>
        ))}
      </div>
    );
  }
  return (
    <div className="abg-root" data-look={look} style={rootStyle}>
      <div className="abg-strip">
        {tabs.map((tab) => (
          <Tab key={tab.title} look={look} tab={tab} />
        ))}
      </div>
      <div className="abg-sidebar">
        {rows.map((row) => (
          <Row key={row.title} look={look} row={row} />
        ))}
      </div>
    </div>
  );
}
