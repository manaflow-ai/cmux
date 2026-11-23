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
const LIST_TRIES = 3;
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
  /**
   * The provider ids of this VM's public egress rules, read page by page (`first`: stop at the first one).
   *
   * The list is offset-paged, so a rule added or deleted between two pages shifts the rest, and a plain next-offset
   * read would skip a rule or read one twice; a revoke's read-back could then call a VM off that still has a rule.
   * So each page after the first starts one rule early: its first rule must be the previous page's last, and the
   * total must not change. Any net shift at a page boundary breaks one of the two, and the whole list is read again
   * (LIST_TRIES times, then 503). A rule seen is real whatever moved after, so `first` returns at once.
   *
   * That catches every rule that was there for the whole read. A rule added during it, at a place already read, can
   * still be missed (an add and a delete before the boundary leave no shift): see `confirmOff`.
   */
  const egressRules = (operation: string, id: string, first: boolean) => Effect.gen(function* () {
    const invalid = () => new UpstreamError({ operation, status: null });
    for (let attempt = 0; attempt < LIST_TRIES; attempt += 1) {
      const found: string[] = [];
      const listed: string[] = [];
      let offset = 0;
      let total: number | null = null;
      let last: string | null = null;
      let moved = false;
      while (!moved) {
        if (offset >= MAX_RULES) return yield* Effect.fail(invalid());
        const query = new URLSearchParams({ vmId: id, limit: String(PAGE), offset: String(offset) });
        const page = yield* http.json(operation, "GET", `/v5/firewall/rules?${query}`).pipe(
          Effect.flatMap(Schema.decodeUnknown(List)), Effect.mapError((error) => error instanceof UpstreamError ? error : invalid()),
        );
        if (page.rules.length > PAGE || offset + page.rules.length > page.totalCount) return yield* Effect.fail(invalid());
        const rules: Array<{ readonly ruleId: string; readonly rule: unknown }> = [];
        for (const rule of page.rules) {
          const ruleId = decodeRuleId(rule);
          if (Option.isNone(ruleId)) return yield* Effect.fail(invalid());
          rules.push({ ruleId: ruleId.value.id, rule });
        }
        if (last !== null && (page.totalCount !== total || rules[0]?.ruleId !== last)) {
          moved = true;
          break;
        }
        total = page.totalCount;
        // The overlap rule was counted on the page before.
        for (const { ruleId, rule } of last === null ? rules : rules.slice(1)) {
          listed.push(ruleId);
          if (!egressRule(rule, id)) continue;
          found.push(ruleId);
          if (first) return { found, listed };
        }
        if (offset + rules.length >= page.totalCount) return { found, listed };
        const end = rules.at(-1);
        // A page past the first must move past its overlap rule.
        if (end === undefined || (last !== null && rules.length < 2)) return yield* Effect.fail(invalid());
        last = end.ruleId;
        offset += rules.length - 1;
      }
    }
    return yield* Effect.fail(new UpstreamError({ operation, status: 409 }));
  });
  const read = (operation: string, id: string) => egressRules(operation, id, true).pipe(Effect.map(({ found }) => found.length > 0));
  /**
   * Whether the VM reads as off: two whole reads in a row find no egress rule and list the same rules in the same
   * order. Every rule that was there all through the second read is in it, and none allows the Internet; a rule added
   * during the first read is in the second. What no read can rule out is an allow that lands during the last read, at a
   * place already read: an allow racing the revoke, which needs the same vm:network scope and could equally land a
   * moment after this call answers. Keeping those two from overlapping at all needs a per-VM lock; reads cannot.
   */
  const confirmOff = (operation: string, id: string) => Effect.gen(function* () {
    const one = yield* egressRules(operation, id, false);
    if (one.found.length > 0) return false;
    const two = yield* egressRules(operation, id, false);
    return two.found.length === 0 && two.listed.length === one.listed.length && two.listed.every((ruleId, index) => ruleId === one.listed[index]);
  });
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
      const { found: rules } = yield* egressRules(operation, id, false);
      for (const ruleId of rules) {
        // A rule already gone (a concurrent revoke, or the VM's delete) is what this call wants.
        yield* http.json(operation, "DELETE", `/v5/firewall/rules/${encodeURIComponent(ruleId)}`).pipe(
          Effect.catchIf((error) => error instanceof UpstreamError && error.status === 404, () => Effect.void),
        );
      }
      // Read back: a rule a concurrent allow added in between, or a delete the provider dropped, must not pass as off.
      if (!(yield* confirmOff(operation, id))) return yield* Effect.fail(new UpstreamError({ operation, status: 409 }));
      return rules.length;
    }),
  };
};
