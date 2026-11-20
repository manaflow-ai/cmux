// How long a running tool call has run, at its row's edge (CommandRow.tsx, ToolRow.tsx,
// McpCallRows.tsx): "41s", "12m 4s", "1h 3m", counting each second from the call's own start
// (`tool.startedAt`, which acpmux stamps; nothing new is asked of it). Lawrence, 2026-11-19, on a
// "Ran glaeda-gh wait …" row that went on in the background with nothing to say for how long: "would
// be useful to see how long it has been running for".
//
// A leaf of its own, as the hat's times are (subagents/Elapsed.tsx): the page clock's second redraws
// this one text node, never the row, its shimmer or the transcript around it, and its tabular figures
// in a box as wide as the widest text of its shape (`Clock`) keep a tick from moving what sits beside
// it. The clock runs only while the call does and rests while the page is hidden (`useNow`).
//
// A call in the foreground shows its time from a few seconds on, so a quick read or grep never
// flashes one; a call in the background shows it at once, since it is there because it runs long.
// The running turn's line at the bottom (Thinking.tsx), which names the call in flight under
// "Working for", counts the call's own time the same way.
// Once the call ends the row draws no time (Lawrence and Lucas, 2026-11-11 standup); its opened
// Shell card says how long it took (ShellBlock.tsx `took`).
import { Clock } from "../../../ui/Typography";
import { usePageNow } from "../../../ui/pageClock";
import { useNow } from "../subagents/subagentGroupModel";
import { formatDuration } from "./turns";

/// A call in the foreground shows its time from this long on.
export const RUNNING_TIME_FROM_MS = 3_000;

export function RunningTime({
  startedAt,
  background = false,
  meta = false,
  local = false,
}: {
  /** When the call started (epoch ms); none draws nothing. */
  startedAt?: number;
  /** The call went on in the background: its time shows at once. */
  background?: boolean;
  /** Wrapped in the row's edge (`cv-command__meta`), for a row that has no other edge marks. */
  meta?: boolean;
  /** `startedAt` is already on this computer's clock (the live line's `doingAt`), not the session's. */
  local?: boolean;
}) {
  const sessionNow = useNow(!local && startedAt !== undefined);
  const localNow = usePageNow(local && startedAt !== undefined);
  const now = local ? localNow : sessionNow;
  if (startedAt === undefined) return null;
  const ms = Math.max(0, now - startedAt);
  if (!background && ms < RUNNING_TIME_FROM_MS) return null;
  const clock = <Clock className="cv-command__elapsed" text={formatDuration(ms)} />;
  return meta ? <span className="cv-command__meta cv-tool__meta">{clock}</span> : clock;
}
