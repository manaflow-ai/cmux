/**
 * Directory and admission rules this Worker implements, published in every
 * `directory.result.v1` and on the unauthenticated health route.
 *
 * A client feature that depends on a Worker rule reads it from the directory
 * before relying on it. A production deployment that predates the rule then
 * shows up as a missing entry and a truthful "service out of date" state,
 * instead of an opaque admission denial (https://github.com/manaflow-ai/cmux/issues/13458).
 *
 * Entries are additive. Never remove or rename one while a shipped client
 * still requires it; add a new versioned identifier instead.
 */

/** Same-account Macs with `cmux.mac-devices.v1` may enter a host that opted in with `cmux.mac-host.v1` (same app namespace and build tag). */
export const MAC_PEER_INBOUND_RULE = "cmux.mac-peer-inbound.v1";

export const CONTROL_PLANE_RULES: readonly string[] = Object.freeze([MAC_PEER_INBOUND_RULE]);

/** The deployed source revision, when the deploy script published it as a Worker variable. */
export function sourceRevision(value: unknown): string {
  return typeof value === "string" && /^(?:[0-9a-f]{7,64}|unknown)$/.test(value) ? value : "unknown";
}
