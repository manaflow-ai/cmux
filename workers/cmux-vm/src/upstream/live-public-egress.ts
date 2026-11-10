/**
 * Public egress of an existing VM. The provider's firewall allows nothing implicitly; a create with
 * initialNetwork.publicEgress carries one inline rule (initial-network.ts), and allowVmPublicEgress adds the same
 * rule, sourced by exactly this VM, afterwards. revokeVmPublicEgress deletes every such rule, so the VM is back to
 * what it may reach without one: its HTTPS proxies and shared networks. Provider rule ids stay here.
 */
import { Effect, Option, Schema } from "effect";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { UpstreamError, type UpstreamClientService } from "./client.ts";
import type { UpstreamHttp } from "./live-http.ts";

const PAGE = 64;
const MAX_RULES = 256;
const List = Schema.Struct({ rules: Schema.Array(Schema.Unknown), totalCount: Schema.NonNegativeInt });
const RuleId = Schema.Struct({ id: Schema.String.pipe(Schema.minLength(1)) });
const decodeRuleId = Schema.decodeUnknownOption(RuleId);
const Endpoint = Schema.Record({ key: Schema.String, value: Schema.Unknown });
const Rule = Schema.Struct({ action: Schema.Literal("allow"), source: Endpoint, destination: Endpoint });
const decodeRule = Schema.decodeUnknownOption(Rule);

/** The set fields of a matcher (the provider answers unset ones as null). */
const set = (endpoint: Readonly<Record<string, unknown>>) =>
  Object.fromEntries(Object.entries(endpoint).filter(([, value]) => value !== null && value !== undefined));

/**
 * A rule that lets this VM reach the public Internet on every port: destination exactly `{ public: true }`, source
 * exactly this VM. A create's inline rule names "the VM being created" with an empty source, so an empty source in
 * the provider's list for this VM counts too.
 */
const egressRule = (value: unknown, id: string) => {
  const decoded = decodeRule(value);
  if (Option.isNone(decoded)) return false;
  const source = set(decoded.value.source);
  const destination = set(decoded.value.destination);
  const sourceKeys = Object.keys(source);
  const sourceOk = sourceKeys.length === 0 || (sourceKeys.length === 1 && source["vmId"] === id);
  return sourceOk && Object.keys(destination).length === 1 && destination["public"] === true;
};

export const makePublicEgress = (http: UpstreamHttp): Pick<UpstreamClientService, "readVmPublicEgress" | "allowVmPublicEgress" | "revokeVmPublicEgress"> => {
  /** The provider ids of this VM's public egress rules, every page read (at most MAX_RULES rules). */
  const egressRules = (operation: string, id: string) => Effect.gen(function* () {
    const invalid = () => new UpstreamError({ operation, status: null });
    const found: string[] = [];
    let offset = 0;
    while (offset < MAX_RULES) {
      const query = new URLSearchParams({ vmId: id, limit: String(PAGE), offset: String(offset) });
      const page = yield* http.json(operation, "GET", `/v5/firewall/rules?${query}`).pipe(
        Effect.flatMap(Schema.decodeUnknown(List)), Effect.mapError((error) => error instanceof UpstreamError ? error : invalid()),
      );
      if (page.rules.length > PAGE || offset + page.rules.length > page.totalCount) return yield* Effect.fail(invalid());
      for (const rule of page.rules) {
        if (!egressRule(rule, id)) continue;
        const ruleId = decodeRuleId(rule);
        if (Option.isNone(ruleId)) return yield* Effect.fail(invalid());
        found.push(ruleId.value.id);
      }
      offset += page.rules.length;
      if (offset >= page.totalCount) return found;
      if (page.rules.length === 0) return yield* Effect.fail(invalid());
    }
    return yield* Effect.fail(invalid());
  });
  const read = (operation: string, id: string) => egressRules(operation, id).pipe(Effect.map((rules) => rules.length > 0));
  return {
    readVmPublicEgress: (_vm, { owns }) =>
      Effect.sync(() => upstreamIdOf(owns)).pipe(Effect.flatMap((id) => read("readVmPublicEgress", id))),
    allowVmPublicEgress: (_vm, { owns }) => Effect.gen(function* () {
      const operation = "allowVmPublicEgress";
      const id = yield* Effect.sync(() => upstreamIdOf(owns));
      if (yield* read(operation, id)) return;
      yield* http.json(operation, "POST", "/v5/firewall/rules", {
        action: "allow", source: { vmId: id }, destination: { public: true },
      });
    }),
    revokeVmPublicEgress: (_vm, { owns }) => Effect.gen(function* () {
      const operation = "revokeVmPublicEgress";
      const id = yield* Effect.sync(() => upstreamIdOf(owns));
      const rules = yield* egressRules(operation, id);
      for (const ruleId of rules) {
        // A rule already gone (a concurrent revoke, or the VM's delete) is what this call wants.
        yield* http.json(operation, "DELETE", `/v5/firewall/rules/${encodeURIComponent(ruleId)}`).pipe(
          Effect.catchIf((error) => error instanceof UpstreamError && error.status === 404, () => Effect.void),
        );
      }
      // Read back: a rule a concurrent allow added in between, or a delete the provider dropped, must not pass as off.
      if (yield* read(operation, id)) return yield* Effect.fail(new UpstreamError({ operation, status: 409 }));
      return rules.length;
    }),
  };
};
