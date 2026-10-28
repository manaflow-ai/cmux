/** Replacement accepts credentials but returns only the public VM id and hostname. */
import { Schema } from "effect";
import { VmId } from "../lib/ids.ts";
import { VmHttpsProxy } from "./initial-network.ts";

export const ReplaceVmHttpsProxyRequest = Schema.Struct({
  destination: VmHttpsProxy.fields.destination,
  headers: VmHttpsProxy.fields.headers,
}).annotations({
  identifier: "ReplaceVmHttpsProxyRequest",
  description: "Replace an existing creation-time HTTPS proxy; destinations must remain approved by the deployment. Omitted headers clear the previous header set.",
  parseOptions: { onExcessProperty: "error" },
  message: () => ({ message: "Invalid HTTPS proxy replacement", override: true }),
});
export type ReplaceVmHttpsProxyRequest = typeof ReplaceVmHttpsProxyRequest.Type;

export class VmHttpsProxyReceipt extends Schema.Class<VmHttpsProxyReceipt>("VmHttpsProxyReceipt")({
  id: VmId,
  hostname: Schema.String,
}) {}
