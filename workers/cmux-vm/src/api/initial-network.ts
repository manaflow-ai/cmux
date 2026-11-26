/** Creation-time networking; proxy credentials are input-only. */
import { Redacted, Schema } from "effect";

export const VmProxyHeaders = Schema.Redacted(Schema.Record({ key: Schema.String, value: Schema.String })).annotations({
  identifier: "VmProxyHeaders",
  description: "Additional headers sent to the approved HTTPS proxy. Write-only; never returned with the VM.",
  jsonSchema: { type: "object", additionalProperties: { type: "string" }, maxProperties: 16, writeOnly: true },
});

export const VmHttpsProxy = Schema.Struct({
  hostname: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(253)),
  destination: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(2048)).annotations({
    description: "A bare HTTPS origin enabled by the deployment's proxy policy.",
  }),
  headers: Schema.optionalWith(VmProxyHeaders, { default: () => Redacted.make<Readonly<Record<string, string>>>({}) }),
}).annotations({ identifier: "VmHttpsProxy", parseOptions: { onExcessProperty: "error" } });

export const VmEgressAllowlist = Schema.Struct({
  mode: Schema.Literal("allowlist"),
  presets: Schema.optionalWith(Schema.Array(Schema.String.pipe(Schema.maxLength(32))).pipe(Schema.maxItems(16)), { default: () => [] }).annotations({
    description: "Named groups of exact host names: anthropic, openai, openrouter, opencode, github, npm, pypi, rust.",
  }),
  domains: Schema.optionalWith(Schema.Array(Schema.String.pipe(Schema.maxLength(253))).pipe(Schema.maxItems(48)), { default: () => [] }).annotations({
    description: "Exact host names (no wildcard, no address), reached over HTTPS on 443 only.",
  }),
}).annotations({
  identifier: "VmEgressAllowlist",
  description: "The VM reaches no public address: only these exact HTTPS names (plus the names every cmux VM needs: its CLI downloads and GitHub releases), and its HTTPS proxies. Conflicts with publicEgress true.",
  parseOptions: { onExcessProperty: "error" },
});

export const InitialVmNetwork = Schema.Struct({
  publicEgress: Schema.optionalWith(Schema.Boolean, { default: () => false }),
  httpsProxies: Schema.optionalWith(Schema.Array(VmHttpsProxy).pipe(Schema.maxItems(8)), { default: () => [] }),
  egress: Schema.optionalWith(VmEgressAllowlist, { exact: true }),
}).annotations({
  identifier: "InitialVmNetwork",
  description: "Network intent for the new VM only. Requires vm:network in addition to vm:write. Omit to keep the private default.",
  parseOptions: { onExcessProperty: "error" },
  // An invalid nested header must not include its value in a decode error.
  message: () => ({ message: "Invalid initial VM network policy", override: true }),
});

export type InitialVmNetwork = typeof InitialVmNetwork.Type;

export const InitialVmNetworkReceipt = Schema.Struct({
  publicEgress: Schema.Boolean,
  httpsProxyHosts: Schema.Array(Schema.String),
  allowedDomains: Schema.optional(Schema.Array(Schema.String)).annotations({
    description: "Present for an allowlist create: every exact HTTPS name the VM may reach besides its proxies.",
  }),
}).annotations({
  identifier: "InitialVmNetworkReceipt",
  description: "Accepted creation-time policy. Proxy credentials and destination origins are never returned.",
});
