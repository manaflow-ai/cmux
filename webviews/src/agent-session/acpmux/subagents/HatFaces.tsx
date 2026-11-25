import type { CSSProperties, MouseEvent } from "react";
import { AgentIdentity } from "./AgentIdentity";
import { faceLayout } from "./hatFacesModel";
import { PHASE_DWELL_MS } from "./hatStep";
import { useDwell } from "./useDwell";
import { useGlideAround } from "./trayGlide";

/// One subagent's icon in the folded hat header (Leo, 2026-11-22: "show a lot of icons (of subagents)
/// and be able to thumb through them when my cursor is hovering over them to be able to parse who's
/// who"). Its name and state are its tooltip, shown at once while the pointer crosses the row.
export type HatFace = {
  key: string;
  /// The subagent or started chat this icon opens.
  target: { kind: "agent"; id: string } | { kind: "session"; id: string };
  harness?: string;
  tone: number;
  icon: string;
  name: string;
  state: "running" | "done" | "failed" | "stopped";
  stateText: string;
};

/// The width the spread icons take at most, and a narrow header's.
export const FACE_CAP = 140;
export const FACE_CAP_NARROW = 64;
/// The fan arm's resting step.
export const FACE_FAN_STEP = 6;

/// The folded header's subagent icons (hatFaces.experiment.ts). Each is its own hover target with
/// its own tooltip (ui/titleTooltips.ts: instant, above, so crossing the row reads each name in
/// turn); a click opens that subagent and never toggles the hat.
export function HatFaces({
  faces,
  size,
  narrow,
  arm,
  onOpen,
  onOpenSession,
}: {
  faces: readonly HatFace[];
  size: number;
  narrow: boolean;
  arm: "spread" | "fan";
  onOpen: (id: string) => void;
  onOpenSession?: (sessionId: string) => void;
}) {
  const cap = narrow ? FACE_CAP_NARROW : FACE_CAP;
  // How many icons the row is laid out for is held as the header's words are (hatStep.ts, 1.6 s), so
  // twenty subagents joining at once widen the row once, not twenty times, and the words after it glide
  // to their new place once (SubagentTray `useGlide`). The icons drawn are always the newest list's.
  const count = Math.min(faces.length, useDwell(faces.length, PHASE_DWELL_MS));
  const rest = arm === "fan" ? Math.min(cap, size + (count - 1) * FACE_FAN_STEP) : cap;
  const layout = faceLayout(count, size, rest);
  // The row's new width and the words' glide land in the same commit (trayGlide.ts `useGlideAround`).
  useGlideAround(layout.width);
  // The fan spreads to the spread arm's layout on hover, drawn over the header so nothing moves.
  const open = arm === "fan" ? faceLayout(count, size, FACE_CAP) : layout;
  const shown = faces.slice(0, layout.shown);
  const click = (face: HatFace) => (event: MouseEvent) => {
    event.stopPropagation();
    event.preventDefault();
    if (face.target.kind === "agent") onOpen(face.target.id);
    else onOpenSession?.(face.target.id);
  };
  return (
    <span
      className="acpmux-hat-faces"
      data-hat-faces={arm}
      data-count={faces.length}
      style={
        {
          "--hat-face-width": `${layout.width}px`,
          "--hat-face-size": `${size}px`,
          "--hat-face-step": `${layout.step}px`,
          "--hat-face-open-step": `${open.step}px`,
          "--hat-face-open-width": `${open.width}px`,
        } as CSSProperties
      }
    >
      <span className="acpmux-hat-faces__row">
        {shown.map((face, index) => (
          // The faces sit inside the hat's header <button>, so a nested <button> is invalid HTML; the
          // header keeps keyboard focus and opens the list, and a click on a face is the pointer shortcut.
          // oxlint-disable-next-line jsx-a11y/click-events-have-key-events
          <span
            key={face.key}
            className="acpmux-hat-face"
            data-hat-face={face.key}
            data-state={face.state}
            style={{ "--hat-face-index": index, zIndex: index + 1 } as CSSProperties}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="button"
            tabIndex={-1}
            aria-label={`${face.name}, ${face.stateText}`}
            // tooltip-allow: an icon names its own subagent; the header's words say the counts.
            title={face.name}
            data-tooltip-detail={face.stateText}
            data-tooltip-instant=""
            data-tooltip-force=""
            data-tooltip-side="top"
            onClick={click(face)}
          >
            <AgentIdentity harness={face.harness} tone={face.tone} size={size} fallback={face.icon} plain />
          </span>
        ))}
      </span>
      {layout.more > 0 && (
        // Only the figure: the counts after the row already say how many there are.
        <span className="acpmux-hat-faces__more" aria-hidden="true">
          +{layout.more}
        </span>
      )}
    </span>
  );
}
