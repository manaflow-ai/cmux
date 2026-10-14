// Which subagents the composer strip shows (StripSubagents.tsx): the ones running or waiting on the
// user. One that ends stays a moment with its done or failed glyph (LINGER_MS), then leaves with
// the strip's exit motion (LEAVE_MS) and is gone. A subagent the strip never saw running (one that
// ended before the chat was shown) never shows.
import { useEffect, useMemo, useRef, useState } from "react";
import type { Subagent } from "../subagents/subagentFold";
import { subagentStatus, type SubagentStatus } from "../summary/SubagentStatusList";

export const LINGER_MS = 2000;
/// The exit motion's length (composerStrip.css: --acpmux-strip-motion, at most 150 ms).
export const LEAVE_MS = 150;

export type StripSubagent = { agent: Subagent; status: SubagentStatus; leaving: boolean };

const live = (status: SubagentStatus) => status === "running" || status === "waiting";

function reducedMotion(): boolean {
  return globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
}

export function useStripSubagents(agents: readonly Subagent[], waiting: ReadonlySet<string>): StripSubagent[] {
  const statuses = useMemo(
    () => agents.map((agent) => ({ agent, status: subagentStatus(agent, waiting) })),
    [agents, waiting],
  );
  // The ones seen running, and of those that ended, which are leaving or gone.
  const [seen, setSeen] = useState<ReadonlySet<string>>(() => new Set());
  const [ended, setEnded] = useState<ReadonlyMap<string, "leaving" | "gone">>(() => new Map());
  // One timer per subagent and phase, kept across renders: a change elsewhere never restarts one.
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const liveIds = statuses.filter((entry) => live(entry.status)).map((entry) => entry.agent.id);
  const liveKey = liveIds.join(",");
  useEffect(() => {
    if (liveIds.every((id) => seen.has(id) && !ended.has(id))) return;
    for (const id of liveIds)
      for (const key of [`${id}:leaving`, `${id}:gone`]) {
        clearTimeout(timers.current.get(key));
        timers.current.delete(key);
      }
    setSeen((current) => new Set([...current, ...liveIds]));
    // One that runs again (a resumed subagent) shows again.
    setEnded((current) => {
      if (!liveIds.some((id) => current.has(id))) return current;
      const next = new Map(current);
      for (const id of liveIds) next.delete(id);
      return next;
    });
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the live ids, by value
  }, [liveKey]);
  const lingering = statuses
    .filter((entry) => !live(entry.status) && seen.has(entry.agent.id) && ended.get(entry.agent.id) !== "gone")
    .map((entry) => entry.agent.id);
  useEffect(() => {
    const mark = (id: string, phase: "leaving" | "gone") => setEnded((current) => new Map(current).set(id, phase));
    for (const id of lingering) {
      const phase = ended.get(id) === "leaving" ? "gone" : "leaving";
      const key = `${id}:${phase}`;
      if (timers.current.has(key)) continue;
      const delay = phase === "leaving" ? LINGER_MS : reducedMotion() ? 0 : LEAVE_MS;
      timers.current.set(
        key,
        setTimeout(() => mark(id, phase), delay),
      );
    }
  });
  useEffect(() => {
    const pending = timers.current;
    return () => pending.forEach(clearTimeout);
  }, []);
  return statuses
    .filter((entry) => live(entry.status) || lingering.includes(entry.agent.id))
    .sort((a, b) => a.agent.startedAt - b.agent.startedAt)
    .map((entry) => ({ ...entry, leaving: ended.get(entry.agent.id) === "leaving" }));
}
