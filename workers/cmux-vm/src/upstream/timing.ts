/**
 * How long one request spent waiting on the provider: every upstream call the request made adds its ms (send to the
 * provider's answer headers, plus the body read when it comes after: timedUpstreamBody) to the request's own tally, and the answer carries it as `server-timing: upstream;dur=MS;
 * desc="N calls"`. A caller that times the whole request (cmux-platform's start trace) subtracts it to split the
 * provider's time from ours (cmuxterm-hq goals/cloud-resume-gap.md). Concurrent calls add up, so on a request that
 * fans out the sum can pass the wall time. Only numbers: no id, path or body.
 */
import { HttpApp, HttpServerResponse } from "@effect/platform";
import { Effect, FiberRef } from "effect";

export interface UpstreamTally {
  ms: number;
  calls: number;
  /**
   * cmux-vm's own serial steps on the request's path, by name (ms): `own` the caller gate (scope, rate limit and the
   * ownership read), `admit` the wait for a provider operation slot. Inside `own`, which waits for two reads at once,
   * `rate` is the tenant limits object's rate spend and `read` the Postgres ownership read, so the slower one is named. The caller's trace reads which of cmux-vm's
   * steps holds its time past the provider's (cmuxterm-hq goals/cloud-resume-gap.md). Numbers only.
   */
  steps?: Record<string, number>;
}

/** cmux-vm's own steps a caller's trace can name (fixed tokens, never ids). */
export type StepName = "own" | "rate" | "read" | "admit";
const STEP_ORDER: ReadonlyArray<StepName> = ["own", "rate", "read", "admit"];

/** The request's tally; null outside a request (cron, tests that call the client directly). */
export const UpstreamTime: FiberRef.FiberRef<UpstreamTally | null> = FiberRef.unsafeMake<UpstreamTally | null>(null);

/** Adds one upstream call that took `ms` to the running request's tally, if there is one. */
export const noteUpstream = (ms: number): Effect.Effect<void> =>
  Effect.flatMap(FiberRef.get(UpstreamTime), (tally) =>
    Effect.sync(() => {
      if (tally === null) return;
      tally.ms += Math.max(0, ms);
      tally.calls += 1;
    }),
  );

/** Names one of cmux-vm's own steps on the running request's answer (`server-timing: NAME;dur=MS`); `name` is a fixed token. */
export const noteStep = (name: StepName, ms: number): Effect.Effect<void> =>
  Effect.flatMap(FiberRef.get(UpstreamTime), (tally) =>
    Effect.sync(() => {
      if (tally === null) return;
      const steps = (tally.steps ??= {});
      steps[name] = (steps[name] ?? 0) + Math.max(0, ms);
    }),
  );

/** `effect`, one of cmux-vm's own steps, named on the request's answer however it ends. */
export const timedStep = <A, E, R>(name: StepName, effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> =>
  Effect.suspend(() => {
    const start = Date.now();
    return Effect.ensuring(effect, Effect.suspend(() => noteStep(name, Date.now() - start)));
  });

/**
 * Adds `ms` spent reading an upstream answer's body after its headers (the same call, so no new call is counted) to the
 * running request's tally, if there is one: a body the provider streams slowly is the provider's time, not ours.
 */
export const noteUpstreamBody = (ms: number): Effect.Effect<void> =>
  Effect.flatMap(FiberRef.get(UpstreamTime), (tally) =>
    Effect.sync(() => {
      if (tally !== null) tally.ms += Math.max(0, ms);
    }),
  );

/** `read`, the body read of an upstream answer `timedUpstream` already counted, its ms added to the same tally. */
export const timedUpstreamBody = <A, E, R>(read: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> =>
  Effect.suspend(() => {
    const start = Date.now();
    return Effect.ensuring(read, Effect.suspend(() => noteUpstreamBody(Date.now() - start)));
  });

/** `effect`, one upstream call, counted in the request's tally however it ends (an answer, an error or a timeout). */
export const timedUpstream = <A, E, R>(effect: Effect.Effect<A, E, R>): Effect.Effect<A, E, R> =>
  Effect.suspend(() => {
    const start = Date.now();
    return Effect.ensuring(effect, Effect.suspend(() => noteUpstream(Date.now() - start)));
  });

export const serverTiming = (tally: UpstreamTally): string =>
  [
    `upstream;dur=${Math.round(tally.ms)};desc="${tally.calls} call${tally.calls === 1 ? "" : "s"}"`,
    // In path order, not in the order the steps finished (`rate` and `read` run at once and end before `own`).
    ...STEP_ORDER.flatMap((name) => {
      const ms = tally.steps?.[name];
      return ms === undefined ? [] : [`${name};dur=${Math.round(ms)}`];
    }),
  ].join(", ");

/**
 * Runs `app` with a fresh tally and names it on the answer when any upstream call was made. The header goes on as the
 * answer is sent (a pre-response handler): the web handler turns the answer into a Response inside `app`, before a
 * middleware's own map of it would run (@effect/platform HttpApp.toHandled).
 */
export const withUpstreamTiming = <E, R>(app: HttpApp.Default<E, R>): HttpApp.Default<E, R> =>
  Effect.suspend(() => {
    const tally: UpstreamTally = { ms: 0, calls: 0 };
    const named = HttpApp.appendPreResponseHandler((_request, response) =>
      Effect.succeed(
        tally.calls === 0 ? response : HttpServerResponse.setHeader(response, "server-timing", serverTiming(tally)),
      ),
    );
    return Effect.locally(Effect.zipRight(named, app), UpstreamTime, tally);
  });
