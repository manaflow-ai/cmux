import type { Translate } from "../i18n";
import { SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { agentTone } from "./agentTones";
import type { HatFace } from "./HatFaces";
import { endedInFailure, type TrayItem } from "./runningTray";
import { STATE_LABEL } from "./subagentGroupModel";
import { subagentTaskLabel } from "./subsessions";

/// The gap between icons while they fit side by side, as the stacked marks' (subagents.css).
export const FACE_GAP = 3;
/// The smallest step between overlapping icons that still leaves each a strip the pointer can find.
export const FACE_MIN_STEP = 5;

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
    if (item.kind === "command" || item.kind === "turn" || seen.has(item.id)) continue;
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
