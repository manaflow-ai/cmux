import { Effect } from "effect";
import type { Vm } from "freestyle";
import { isIP } from "node:net";
import { shellQuote } from "./cmuxTuiDaemon";
import { PRIVATE_NETWORK_ANNOUNCE_SCRIPT } from "../images/network";
import { ProviderError } from "./types";

/**
 * A resumed snapshot can acquire a VPC address before the provider learns its
 * link-layer mapping. Announce only addresses actually assigned to this guest:
 * one gratuitous ARP for IPv4 and one unsolicited neighbor advertisement for
 * IPv6. One available family is sufficient; clients retain their address race.
 * No routes, firewall rules, interfaces, or running sessions are changed.
 * The announcer itself (PRIVATE_NETWORK_ANNOUNCE_SCRIPT) is shared with the
 * boot supervisor's periodic announce (images/network.ts).
 */
export function freestyleNetworkAnnouncementCommand(addresses: readonly string[]): string {
  return `python3 -c ${shellQuote(PRIVATE_NETWORK_ANNOUNCE_SCRIPT)} ${shellQuote(JSON.stringify(addresses))}`;
}

/**
 * The shared private-address setup every lifecycle path runs. It fails closed:
 * a machine with no usable address has no route to its daemon or its ports.
 * Create, restore, and attach surface that failure; a wake reports it without
 * failing, having nothing to roll back (see FreestyleProvider.resume).
 */
export function announceFreestyleNetwork(
  vm: Pick<Vm, "exec">,
  addresses: readonly string[],
  options: { readonly validateOnly?: boolean } = {},
) {
  const valid = [...new Set(addresses.filter((address) => isIP(address) !== 0))];
  if (valid.length === 0) {
    return Effect.fail(new ProviderError("freestyle", "Private network has no valid assigned address"));
  }
  if (options.validateOnly) return Effect.void;
  return Effect.tryPromise({
    try: () => vm.exec({ command: freestyleNetworkAnnouncementCommand(valid), linuxUser: "root", timeoutMs: 5_000 }),
    catch: (cause) => new ProviderError("freestyle", "announce private network", cause),
  }).pipe(Effect.flatMap((result) => result.statusCode === 0
    ? Effect.void
    : Effect.fail(new ProviderError("freestyle", "Private network announcement failed", result.stderr))));
}
