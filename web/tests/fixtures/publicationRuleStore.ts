import { makeVmPublicationProvider } from "../../services/vm-publications/provider";

export type FakeIngressRule = {
  readonly id: string;
  readonly domain: string;
  readonly protocol: "http";
  readonly source: { readonly public: true };
  readonly destination: { readonly vmId: string; readonly port: number };
  readonly createdAt: string;
};

/** An exact public HTTP ingress rule, the shape publications create. */
export function ingressRule(id: string, domain: string, vmId: string, createdAt = "2026-09-02T12:00:00.000Z"): FakeIngressRule {
  return { id, domain, protocol: "http", source: { public: true }, destination: { vmId, port: 3_000 }, createdAt };
}

/** A real publication provider over an in-memory Freestyle TLS rule store. */
export function publicationRuleStore(initial: FakeIngressRule[]) {
  const rules = [...initial];
  const deleted: string[] = [];
  const updated: string[] = [];
  let next = 0;
  const client = {
    tls: {
      rules: {
        list: async (options: { limit?: number; offset?: number } = {}) => {
          const offset = options.offset ?? 0;
          return { rules: rules.slice(offset, offset + (options.limit ?? 100)), totalCount: rules.length };
        },
        get: async (id: string) => {
          const rule = rules.find((candidate) => candidate.id === id);
          if (!rule) throw Object.assign(new Error("not found"), { status: 404, code: "NOT_FOUND" });
          return rule;
        },
        create: async (options: Omit<FakeIngressRule, "id" | "createdAt">) => {
          const rule = { ...options, id: `tls-created-${next++}`, createdAt: "2026-09-02T13:00:00.000Z" } as FakeIngressRule;
          rules.push(rule);
          return rule;
        },
        update: async (id: string, options: Omit<FakeIngressRule, "id" | "createdAt">) => {
          updated.push(id);
          const index = rules.findIndex((candidate) => candidate.id === id);
          rules[index] = { ...rules[index]!, ...options };
          return rules[index]!;
        },
        delete: async (id: string) => {
          deleted.push(id);
          const index = rules.findIndex((candidate) => candidate.id === id);
          if (index >= 0) rules.splice(index, 1);
        },
      },
    },
  };
  return { provider: makeVmPublicationProvider(() => client as never), rules, deleted, updated };
}
