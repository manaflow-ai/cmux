import type { CSSProperties, MouseEvent } from "react";
import type { Translate } from "../i18n";
import { AgentIdentity } from "./AgentIdentity";
import { SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { agentTone } from "./agentTones";
import { PHASE_DWELL_MS } from "./hatStep";
import { useDwell } from "./HatStepSlot";
import { endedInFailure, type TrayItem } from "./runningTray";
import { STATE_LABEL } from "./subagentGroupModel";
import { subagentTaskLabel } from "./subsessions";
import { useGlideAround } from "./trayMotion";

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

/// The gap between icons while they fit side by side, as the stacked marks' (subagents.css).
export const FACE_GAP = 3;
/// The smallest step between overlapping icons that still leaves each a strip the pointer can find.
export const FACE_MIN_STEP = 5;
/// The width the spread icons take at most, and a narrow header's.
export const FACE_CAP = 140;
export const FACE_CAP_NARROW = 64;
/// The fan arm's resting step.
export const FACE_FAN_STEP = 6;

/// The subagents and chats it started, running first then ended, each once. Commands are not
/// subagents: their kind keeps its own mark. Computed when the lists change, never per tick.
export function hatFaces(
  t: Translate,
  items: readonly TrayItem[],
  finished: readonly TrayItem[],
  chatHarness: string | undefined,
): readonly HatFace[] {
  const faces: HatFace[] = [];
  const seen = new Set<string>();
  for (const [item, ended] of [
    ...items.map((item) => [item, false] as const),
    ...finished.map((item) => [item, true] as const),
  ]) {
    if (item.kind === "command" || seen.has(item.id)) continue;
    seen.add(item.id);
    if (item.kind === "agent") {
      const { agent } = item;
      const state = faceState(item, ended || agent.state !== "running");
      let label: string | undefined;
      faces.push({
        key: item.id,
        target: { kind: "agent", id: agent.id },
        harness: agent.harness ?? chatHarness,
        tone: agentTone(agent.id),
        icon: SUBAGENT_FALLBACK,
        // Read only for the faces the row draws (HatFaceRow `shown`): a tray of 300 subagents labels
        // the few that fit, never every one (subagent-tray.test.tsx, 300 collapsed agents).
        get name() {
          return (label ??= subagentTaskLabel(t, agent));
        },
        state,
        stateText: t(STATE_LABEL[agent.state as keyof typeof STATE_LABEL] ?? STATE_LABEL.completed),
      });
    } else {
      const state = faceState(item, ended || item.session.state !== "running");
      faces.push({
        key: item.id,
        target: { kind: "session", id: item.session.sessionId },
        harness: item.session.harness,
        tone: agentTone(item.session.sessionId),
        icon: "agent.chat",
        name: item.session.title,
        state,
        stateText: t(
          state === "running"
            ? STATE_LABEL.running
            : state === "failed"
              ? STATE_LABEL.failed
              : state === "stopped"
                ? STATE_LABEL.cancelled
                : STATE_LABEL.completed,
        ),
      });
    }
  }
  return faces;
}

function faceState(item: TrayItem, ended: boolean): HatFace["state"] {
  if (!ended) return "running";
  if (endedInFailure(item)) return "failed";
  if (item.kind === "agent" && (item.agent.state === "cancelled" || item.agent.state === "disconnected"))
    return "stopped";
  return "done";
}

/// Where each icon sits: side by side while they fit the cap, then overlapping evenly, and past the
/// smallest step only the first ones with a "+N" after them. Pure, so the gallery and tests read it.
export function faceLayout(
  count: number,
  size: number,
  cap: number,
): { step: number; shown: number; more: number; width: number } {
  if (count <= 0) return { step: 0, shown: 0, more: 0, width: 0 };
  const side = size + FACE_GAP;
  if (count === 1 || size + (count - 1) * side <= cap)
    return { step: side, shown: count, more: 0, width: size + (count - 1) * side };
  const step = (cap - size) / (count - 1);
  if (step >= FACE_MIN_STEP) return { step, shown: count, more: 0, width: cap };
  const shown = Math.max(1, Math.floor((cap - size) / FACE_MIN_STEP) + 1);
  return { step: FACE_MIN_STEP, shown, more: count - shown, width: size + (shown - 1) * FACE_MIN_STEP };
}

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
  // The row's new width and the words' glide land in the same commit (trayMotion.tsx `useGlideAround`).
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
