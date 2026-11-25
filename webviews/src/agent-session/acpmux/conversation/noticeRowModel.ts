/// The clock time a notice's repeats name, "last 09:40Z" (InboxNoticeCard.tsx): UTC hours and
/// minutes, as the detectors' own text names times, so every machine's reader reads one time.
/// Empty for no time.
export function noticeRepeatClock(at: number | undefined): string {
  if (at === undefined || !Number.isFinite(at) || at <= 0) return "";
  // acpmux records `at` in milliseconds; a seconds value (an older record) reads the same.
  const ms = at < 1e12 ? at * 1000 : at;
  return `${new Date(ms).toISOString().slice(11, 16)}Z`;
}
