import { formatReleaseDate } from "./model";

/** A local, readable publication time. Old day-only notes never invent a time. */
export function buildLabel(build: { date: string; publishedAt?: string }, language: string): string {
  if (!build.publishedAt) return formatReleaseDate(build.date, language);
  const date = new Date(build.publishedAt);
  if (!Number.isFinite(date.getTime())) return formatReleaseDate(build.date, language);
  const day = new Intl.DateTimeFormat(language, { month: "short", day: "numeric" }).format(date);
  const time = new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }).format(date);
  return `${day} · ${time}`;
}
