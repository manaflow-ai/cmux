import * as Schema from "effect/Schema";

/**
 * The value shapes the hang report wire schemas share (``wireSchema.ts`` and
 * ``fieldDataSchema.ts``): bounded numbers, optional fields as the Swift
 * client's JSONEncoder writes them, and the version and day patterns.
 */

export const MAX_DURATION_MS = 86_400_000;
export const MAX_COUNT = 1_000_000_000;

export const UUID_PATTERN = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
export const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
// The Swift client sends `^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$` (or "0") for the
// app version, app build and macOS version. The version also accepts the
// release pipeline's "0.70.0-nightly.<run>" form, and the build a long numeric
// run id ("2123456789012"), in case the client forwards them unchanged.
const CLIENT_VERSION = String.raw`[0-9]{1,6}(?:\.[0-9]{1,6}){0,3}`;
export const APP_VERSION_PATTERN = new RegExp(`^(?:${CLIENT_VERSION}|\\d{1,6}(?:\\.\\d{1,6}){0,2}-[a-z]{1,16}(?:\\.\\d{1,20})?)$`);
export const APP_BUILD_PATTERN = new RegExp(`^(?:${CLIENT_VERSION}|\\d{1,20}(?:\\.\\d{1,6}){0,2})$`);
export const OS_VERSION_PATTERN = new RegExp(`^${CLIENT_VERSION}$`);
export const CHANNELS = ["nightly", "dev", "rc", "release"] as const;

export const boundedInt = (max: number) => Schema.Number.pipe(Schema.int(), Schema.between(0, max));

/**
 * A Swift `UInt64` (a count, a sum, a trace time or a trace argument): any
 * non-negative integer. JSON numbers above 2^53 - 1 arrive rounded to the
 * nearest double, which is still an integer; that loses the low bits of an
 * id, never a count a person could read.
 */
export const u64 = Schema.Number.pipe(
  Schema.filter((value) => Number.isInteger(value) && value >= 0, { message: () => "not a non-negative integer" }),
);

export const optionalNullable = <S extends Schema.Schema.Any>(schema: S) =>
  Schema.optionalWith(Schema.NullOr(schema), { exact: true });

export const optionalArray = <A, I>(schema: Schema.Schema<A, I>, max: number) =>
  Schema.optionalWith(Schema.Array(schema).pipe(Schema.maxItems(max)), {
    exact: true,
    default: (): ReadonlyArray<A> => [],
  });

export const Uuid = Schema.String.pipe(Schema.pattern(UUID_PATTERN));

export const Day = Schema.String.pipe(
  Schema.pattern(DAY_PATTERN),
  Schema.filter(isCalendarDay, { message: () => "not a calendar day" }),
);

export function isUnique(values: ReadonlyArray<string>): boolean {
  return new Set(values).size === values.length;
}

export function isStrictlyAscending(values: ReadonlyArray<number>): boolean {
  return values.every((value, index) => index === 0 || (values[index - 1] ?? -Infinity) < value);
}

export function isCalendarDay(day: string): boolean {
  const parsed = new Date(`${day}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === day;
}
