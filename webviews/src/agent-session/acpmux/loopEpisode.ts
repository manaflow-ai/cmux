export type LoopEpisode = { episodeId: number; since: number; count: number; diagnosis: string; hint: string };

/** Old daemons omit this field; malformed or cleared summaries must remove attention. */
export function readLoopEpisode(value: unknown): LoopEpisode | undefined {
  if (!value || typeof value !== "object") return undefined;
  const episode = value as Record<string, unknown>;
  if (
    !Number.isSafeInteger(episode.episodeId) ||
    Number(episode.episodeId) < 1 ||
    !Number.isFinite(episode.since) ||
    Number(episode.since) < 0 ||
    !Number.isSafeInteger(episode.count) ||
    Number(episode.count) < 1 ||
    typeof episode.diagnosis !== "string" ||
    !episode.diagnosis ||
    episode.diagnosis.length > 1024 ||
    typeof episode.hint !== "string" ||
    episode.hint.length > 2048
  )
    return undefined;
  return episode as LoopEpisode;
}

/** Attention describes a live turn; it never changes the session's scheduling state. */
export function stuckAttention(summary: {
  status?: unknown;
  state?: unknown;
  turn?: { stalledSince?: unknown } | null;
  loopEpisode?: unknown;
}): { loopEpisode: LoopEpisode | undefined; stalledSince: number | undefined } {
  const live = summary.status !== "closed" && summary.state !== "stopping" && !!summary.turn;
  const since = summary.turn?.stalledSince;
  return {
    loopEpisode: live ? readLoopEpisode(summary.loopEpisode) : undefined,
    stalledSince: live && typeof since === "number" && Number.isFinite(since) && since >= 0 ? since : undefined,
  };
}
