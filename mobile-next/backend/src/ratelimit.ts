// Sliding-window rate limits and lockouts backed by the `rate_events` table.
// Counting and recording are separate statements, so a burst of concurrent
// requests can overshoot a limit by the number in flight; that is acceptable
// for these abuse limits.
import type { Db } from "./db";
import { HttpError } from "./http";

const RETENTION_MS = 24 * 60 * 60 * 1000;
const CLEANUP_PROBABILITY = 0.01;

export async function countEvents(db: Db, bucket: string, k: string, windowMs: number, now = Date.now()): Promise<number> {
  const row = await db.one<{ n: number | string }>(
    "SELECT COUNT(*) AS n FROM rate_events WHERE bucket = ? AND k = ? AND created_at > ?",
    [bucket, k, new Date(now - windowMs)],
  );
  return Number(row?.n ?? 0);
}

export async function recordEvent(db: Db, bucket: string, k: string, now = Date.now()): Promise<void> {
  await db.exec("INSERT INTO rate_events (bucket, k, created_at) VALUES (?, ?, ?)", [bucket, k, new Date(now)]);
  if (Math.random() < CLEANUP_PROBABILITY) {
    await db.exec("DELETE FROM rate_events WHERE created_at < ? LIMIT 1000", [new Date(now - RETENTION_MS)]);
  }
}

/** Throws 429 when `limit` events already exist in the window; otherwise records one. */
export async function consume(db: Db, bucket: string, k: string, limit: number, windowMs: number, now = Date.now()): Promise<void> {
  if ((await countEvents(db, bucket, k, windowMs, now)) >= limit) throw new HttpError(429, "rate_limited");
  await recordEvent(db, bucket, k, now);
}

/**
 * Records a failure. When `threshold` failures fall inside `windowMs`, records a
 * lock event in `${bucket}_lock`; `isLocked` reports a lock younger than `lockMs`.
 */
export async function recordFailure(
  db: Db,
  bucket: string,
  k: string,
  threshold: number,
  windowMs: number,
  now = Date.now(),
): Promise<void> {
  await recordEvent(db, bucket, k, now);
  if ((await countEvents(db, bucket, k, windowMs, now)) >= threshold) {
    await recordEvent(db, `${bucket}_lock`, k, now);
  }
}

export async function isLocked(db: Db, bucket: string, k: string, lockMs: number, now = Date.now()): Promise<boolean> {
  return (await countEvents(db, `${bucket}_lock`, k, lockMs, now)) > 0;
}
