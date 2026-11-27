/** Provider rule ids stay here; an applicable VPC rule is never an owned VM rule. */
import { Effect, Option, Redacted, Schema } from "effect";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { vmNetworkEvidenceOf } from "../proofs/vm-network.ts";
import { UpstreamError, type UpstreamClientService } from "./client.ts";
import type { UpstreamHttp } from "./live-http.ts";

const PAGE = 64;
const MAX_RULES = 256;
const List = Schema.Struct({ rules: Schema.Array(Schema.Unknown), totalCount: Schema.NonNegativeInt });
const Source = Schema.Struct({
  vmId: Schema.String,
  vpcId: Schema.optional(Schema.NullOr(Schema.String)),
  public: Schema.optional(Schema.NullOr(Schema.Boolean)),
  host: Schema.optional(Schema.NullOr(Schema.String)),
  port: Schema.optional(Schema.NullOr(Schema.Number)),
}).annotations({ parseOptions: { onExcessProperty: "error" } });
const Rule = Schema.Struct({
  id: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256)),
  action: Schema.Literal("allow"), protocol: Schema.Literal("http"), domain: Schema.String, source: Source,
});
const decodeRule = Schema.decodeUnknownOption(Rule);

export const makeHttpsProxies = (http: UpstreamHttp): Pick<UpstreamClientService, "replaceVmHttpsProxy"> => ({
  replaceVmHttpsProxy: (_vm, { owns, network }) => Effect.gen(function* () {
    const operation = "replaceVmHttpsProxy";
    const invalid = () => new UpstreamError({ operation, status: null });
    const id = yield* Effect.sync(() => upstreamIdOf(owns));
    const config = vmNetworkEvidenceOf(network).config;
    const proxy = config.httpsProxies[0];
    if (config.publicEgress || config.httpsProxies.length !== 1 || proxy === undefined) return yield* Effect.fail(invalid());
    const ids: string[] = [];
    let offset = 0;
    while (offset < MAX_RULES) {
      const query = new URLSearchParams({ vmId: id, domain: proxy.hostname, limit: String(PAGE), offset: String(offset) });
      const page = yield* http.json(operation, "GET", `/v5/tls?${query}`).pipe(
        Effect.flatMap(Schema.decodeUnknown(List)), Effect.mapError((error) => error instanceof UpstreamError ? error : invalid()),
      );
      if (page.totalCount > MAX_RULES || page.rules.length > PAGE || offset + page.rules.length > page.totalCount) return yield* Effect.fail(invalid());
      for (const value of page.rules) {
        const decoded = decodeRule(value);
        if (Option.isNone(decoded)) continue;
        const rule = decoded.value;
        if (rule.domain === proxy.hostname && rule.source.vmId === id && rule.source.vpcId == null
          && rule.source.public == null && rule.source.host == null && rule.source.port == null) ids.push(rule.id);
      }
      offset += page.rules.length;
      if (offset >= page.totalCount) break;
      if (page.rules.length === 0 || offset === MAX_RULES) return yield* Effect.fail(invalid());
    }
    const ruleId = ids[0];
    if (ruleId === undefined) return "missing";
    if (ids.length !== 1) return "ambiguous";
    if (ruleId === "." || ruleId === "..") return yield* Effect.fail(invalid());
    yield* http.json(operation, "PUT", `/v5/tls/${encodeURIComponent(ruleId)}`, {
      action: "allow", protocol: "http", domain: proxy.hostname, source: { vmId: id },
      destination: proxy.destination, transform: [{ headers: Redacted.value(proxy.headers) }],
    });
    return "updated";
  }),
});
