// l10n-allow-file: gallery design fixtures for the native sidebar's terminal tail pins, not shipped UI.
// Terminal tail pins: a person pins a terminal and the daemon writes that terminal's last
// non-empty output line (ANSI stripped, at most 2 updates/s) as a workspace status entry, which
// the native sidebar draws as one line under the row's name (CmuxNextSidebar
// WorkspaceStatusView: optional SF Symbol + text, entry tint or Palette.textSecondary,
// SidebarStyle.subtitleFont, truncated at the row's end). The daemon picks the entry's icon,
// colour and text; each design here is one choice of those fields, drawn on the sidebar grid
// (design/grid.md §5.4, design/sidebar.md).
import { useState } from "react";
import { StatusGlyph } from "../ui/StatusGlyph";
import "./TerminalTailPinDesigns.css";

export type TerminalTailPinDesign = "icon-line" | "title-prefix" | "tinted" | "plain";

export interface TerminalTailPinDesignsProps {
  design: TerminalTailPinDesign;
  /** Show the "Next output line" control that advances every pinned tail (the update play). */
  live?: boolean;
  /** Swap: the text changes with no animation. Crossfade: ≤120 ms, skipped under reduced motion. */
  swap?: "instant" | "crossfade";
}

type Workspace = {
  id: string;
  title: string;
  selected?: boolean;
  working?: boolean;
  /** The pinned terminal: its tab title and its successive tail lines. */
  pin?: { tab: string; tails: string[] };
};

const workspaces: Workspace[] = [
  {
    id: "cmux",
    title: "cmux-tui daemon",
    selected: true,
    working: true,
    pin: {
      tab: "cargo",
      tails: [
        "Compiling cmux-tui-core v0.1.0 (/src/cmux-tui/crates/cmux-tui-core)",
        "[=====>        ] 41% 312/760 tests",
        "[======>       ] 48% 365/760 tests",
      ],
    },
  },
  { id: "notes", title: "Release notes" },
  {
    id: "web",
    title: "web staging",
    pin: { tab: "deploy", tails: ["Deployed web@a1b2c3 to staging in 48s", "GET /api/health 200 3ms"] },
  },
  { id: "bench", title: "ghostty bench" },
];

/** The `>_` terminal mark, a 12 px glyph (the status mark size), drawn in the line's ink. */
function TerminalGlyph() {
  return (
    <svg className="ttp-glyph" viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
      <path
        d="M2 3.5 4.5 6 2 8.5M6 9h4"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function TailLine({
  design,
  tab,
  text,
  swap,
}: {
  design: TerminalTailPinDesign;
  tab: string;
  text: string;
  swap: "instant" | "crossfade";
}) {
  const shown = design === "title-prefix" ? `${tab} · ${text}` : text;
  const icon = design === "icon-line" || design === "tinted";
  return (
    <span className="ttp-tail" data-design={design}>
      {icon && <TerminalGlyph />}
      {/* Keyed by the text so a crossfade replays on each new line; the box never changes size. */}
      <span key={swap === "crossfade" ? shown : undefined} className="ttp-tail-text" data-swap={swap}>
        {shown}
      </span>
    </span>
  );
}

export function TerminalTailPinDesigns({ design, live = false, swap = "instant" }: TerminalTailPinDesignsProps) {
  const [step, setStep] = useState(0);
  return (
    <div className="ttp-stage">
      <ul className="ttp-sidebar" aria-label="Workspaces">
        {workspaces.map((workspace) => {
          const tail = workspace.pin ? workspace.pin.tails[step % workspace.pin.tails.length]! : undefined;
          return (
            <li
              key={workspace.id}
              className="ttp-row"
              data-selected={workspace.selected || undefined}
              data-has-tail={tail ? "" : undefined}
              aria-label={tail ? `${workspace.title}, ${workspace.pin!.tab}: ${tail}` : workspace.title}
            >
              <span className="ttp-text">
                <span className="ttp-title">{workspace.title}</span>
                {workspace.pin && tail && <TailLine design={design} tab={workspace.pin.tab} text={tail} swap={swap} />}
              </span>
              <span className="ttp-trail">{workspace.working && <StatusGlyph name="working" size={12} />}</span>
            </li>
          );
        })}
      </ul>
      {live && (
        <button type="button" className="ttp-next" onClick={() => setStep((value) => value + 1)}>
          Next output line
        </button>
      )}
    </div>
  );
}
