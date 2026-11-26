import { describe, expect, test } from "bun:test";
import { EDGE_RULE_DOMAIN, edgeRuleCreateRules, edgeRuleFacts, edgeRuleGuestCommand, edgeRuleResolveProblems } from "../scripts/cmux-vm-image/smoke";
import { freestyleEdgeRules } from "../services/vms/drivers/freestyle";

describe("smoke edge-rule clone", () => {
  test("its create carries the rule a gateway-mode create carries", () => {
    const product = freestyleEdgeRules([{ domain: EDGE_RULE_DOMAIN, destinationHost: "cmux-platform-development.debussy.workers.dev", headers: { "x-cmux-image-smoke": "edge-rule" } }]);
    expect(edgeRuleCreateRules()).toEqual(product!);
  });

  test("the guest command prints every fact it is judged on", () => {
    const command = edgeRuleGuestCommand();
    for (const key of ["resolve-public", "resolve-api", "resolve-edge", "resolv.conf", "resolved.conf.d", "resolvectl", "hosts", "resolved-journal"]) {
      expect(command).toContain(`echo "${key}: `);
    }
  });

  test("a clone that resolves both names passes", () => {
    const facts = edgeRuleFacts([
      "hosts-wait-s: 3",
      "resolve-public: 140.82.112.3    github.com ; ",
      "resolve-api: 2606:4700:3030::6815:1   cmux-api-development.debussy.workers.dev ; ",
      "resolve-edge: 10.0.0.1 coderouter.cmux.internal ; ",
    ].join("\n"));
    expect(facts["hosts-wait-s"]).toBe("3");
    expect(edgeRuleResolveProblems(facts)).toEqual([]);
  });

  test("a resolver that gives no answer fails it, naming the name", () => {
    const facts = edgeRuleFacts("resolve-public: FAILED rc=2 ; \nresolve-api: 104.21.1.1 cmux-api-development.debussy.workers.dev ; ");
    expect(edgeRuleResolveProblems(facts)).toEqual(["resolve-public: FAILED rc=2 ;"]);
    expect(edgeRuleResolveProblems({})).toEqual(["resolve-public: no answer", "resolve-api: no answer"]);
  });
});
