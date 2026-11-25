/**
 * Phase timings of one request, logged as one JSON line so `wrangler tail` shows where its time went (the shape of
 * the mesh handler's mesh_vm_attach line). A line names public ids and durations only: never a tenant, a provider id,
 * a request body or a key.
 */
import { Clock, Effect } from "effect";

/** What one request's line carries: milliseconds per phase, plus a few flags and public ids. */
export type TimedPhases = Record<string, unknown>;

/** Runs `effect` and records its wall time in `into[key]` (milliseconds), success or failure. */
export const timedPhase = <A, E, R>(into: TimedPhases | undefined, key: string, effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> =>
  into === undefined
    ? effect
    : Effect.flatMap(Clock.currentTimeMillis, (started) =>
        effect.pipe(Effect.ensuring(Effect.flatMap(Clock.currentTimeMillis, (at) => Effect.sync(() => { into[key] = at - started; })))));

/** One structured Worker log line. */
export const logTimedEvent = (event: string, fields: TimedPhases) => Effect.sync(() => console.error(JSON.stringify({ event, ...fields })));
