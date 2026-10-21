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

export const InitialVmNetwork = Schema.Struct({
  publicEgress: Schema.optionalWith(Schema.Boolean, { default: () => false }),
  httpsProxies: Schema.optionalWith(Schema.Array(VmHttpsProxy).pipe(Schema.maxItems(8)), { default: () => [] }),
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
}).annotations({
  identifier: "InitialVmNetworkReceipt",
  description: "Accepted creation-time policy. Proxy credentials and destination origins are never returned.",
});
