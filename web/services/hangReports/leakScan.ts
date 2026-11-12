/**
 * Defense-in-depth privacy check over a decoded hang report. The schema's
 * patterns and enums already make these shapes impossible; this scan refuses
 * the whole report if one gets through anyway. It returns only a reason code,
 * never the offending string, so nothing from the body reaches a log or a
 * response.
 */

export type LeakReason = "path" | "email" | "url" | "ip_address" | "token";

const UUID_RUN = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/g;
const IPV4 = /(?:^|[^0-9.])\d{1,3}(?:\.\d{1,3}){3}(?![0-9.])|^\d{1,3}(?:\.\d{1,3}){3}$/;
const IPV6 = /(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}/;
// Same rule as the Swift client's PrivacyLeakScanner: a run of 32 or more
// ASCII letters and digits that mixes both.
const ALNUM_RUN = /[A-Za-z0-9]{32,}/g;

/** The first leak shape found in any string of `value`, or null. */
export function scanForLeaks(value: unknown): LeakReason | null {
  for (const text of strings(value)) {
    const reason = leakIn(text);
    if (reason) return reason;
  }
  return null;
}

function leakIn(text: string): LeakReason | null {
  if (text.includes("://")) return "url";
  if (text.includes("/") || text.includes("~")) return "path";
  if (text.includes("@")) return "email";
  if (IPV4.test(text) || IPV6.test(text)) return "ip_address";
  // A UUID is the only long hex-like value a report may carry.
  const withoutUuids = text.replace(UUID_RUN, " ");
  for (const run of withoutUuids.match(ALNUM_RUN) ?? []) {
    if (/\d/.test(run) && /[A-Za-z]/.test(run)) return "token";
  }
  return null;
}

function* strings(value: unknown): Generator<string> {
  if (typeof value === "string") {
    yield value;
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) yield* strings(item);
    return;
  }
  if (value !== null && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      yield key;
      yield* strings(item);
    }
  }
}
