/** Provider fields for this create only; callers cannot choose another VM as source. */
import { Redacted } from "effect";
import { vmNetworkEvidenceOf, type VmNetworkAllowed } from "../proofs/vm-network.ts";

export const initialNetworkBody = <C>(allowed: VmNetworkAllowed<C> | undefined) => {
  const config = allowed === undefined ? undefined : vmNetworkEvidenceOf(allowed).config;
  return {
    firewall: { rules: config?.publicEgress ? [{ action: "allow", source: {}, destination: { public: true } }] : [] },
    ...(config?.httpsProxies.length ? {
      tls: { rules: config.httpsProxies.map((proxy) => ({
        action: "allow",
        domain: proxy.hostname,
        source: {},
        destination: proxy.destination,
        transform: [{ headers: Redacted.value(proxy.headers) }],
      })) },
    } : {}),
  };
};
