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

/** Same-account Macs with `cmux.mac-devices.v1` may enter a host that opted in with `cmux.mac-host.v1`. */
export const MAC_PEER_INBOUND_RULE = "cmux.mac-peer-inbound.v1";
/** Signed Mac metadata capability for the channel-independent peer protocol. */
export const MAC_PEER_CAPABILITY = "cmux.mac-peer.v1";
/** Signed `cmux.mac-peer.v1` descriptors may cross app namespace/build channels. */
export const MAC_PEER_CROSS_CHANNEL_RULE = "cmux.mac-peer-cross-channel.v1";

export const CONTROL_PLANE_RULES: readonly string[] = Object.freeze([MAC_PEER_INBOUND_RULE, MAC_PEER_CROSS_CHANNEL_RULE]);

/**
 * Published only in `account.directory.result.v1`, never in the team
 * directory or health route. A Mac lists and admits the same Stack user's Macs
 * across teams through the account directory only when this rule is present.
 * The cross-channel rule below additionally gates signed namespace/build
 * compatibility.
 */
export const MAC_ACCOUNT_PEER_RULE = "cmux.mac-account-peer.v1";
/** Signed `cmux.mac-peer.v1` descriptors may cross app namespace/build channels. */
export const MAC_ACCOUNT_CROSS_CHANNEL_RULE = "cmux.mac-account-cross-channel.v1";

export const ACCOUNT_DIRECTORY_RULES: readonly string[] = Object.freeze([MAC_ACCOUNT_PEER_RULE, MAC_ACCOUNT_CROSS_CHANNEL_RULE]);

/** The deployed source revision, when the deploy script published it as a Worker variable. */
export function sourceRevision(value: unknown): string {
  return typeof value === "string" && /^(?:[0-9a-f]{7,64}|unknown)$/.test(value) ? value : "unknown";
}
