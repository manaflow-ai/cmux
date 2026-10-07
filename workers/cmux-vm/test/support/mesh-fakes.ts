/**
 * Fakes for the mesh experiment (cx-0op): the mesh tables in memory and the
 * provider's networking routes (private networks, tunnels, firewall rules, VM
 * networks) behind the real live mesh client. Every request is recorded in
 * the shared fake provider's call log, so "nothing reached upstream" checks
 * cover mesh calls too.
 */
import { Layer, Redacted } from "effect";
import { makeMemoryMeshStore } from "../../src/db/mesh-memory.ts";
import { meshConfigLayer, type MeshBudgets } from "../../src/mesh/config.ts";
import { makeUpstreamMesh } from "../../src/upstream/live-mesh.ts";
import { UpstreamMesh } from "../../src/upstream/mesh.ts";
import type { FakeUpstream } from "./fake-upstream.ts";

const UPSTREAM_URL = "https://upstream.test";
const UPSTREAM_KEY = "upstream-test-key";

export interface FakeTunnel {
  readonly id: string;
  readonly clientPublicKey: string | null;
  readonly routes: ReadonlyArray<string>;
  readonly vpc: string;
  readonly ipv4: string;
  /** Changes on every key rotation, as the provider's does. */
  readonly serverPublicKey?: string;
}

export interface FakeRule {
  readonly id: string;
  readonly source: Record<string, unknown>;
  readonly destination: Record<string, unknown>;
  readonly description: string | null;
}

export interface MeshFakeOptions {
  readonly experiment?: boolean;
  readonly tenants?: ReadonlyArray<string>;
  readonly budgets?: Partial<MeshBudgets>;
}

const json = (body: unknown, status = 200) => Response.json(body, { status });

export function makeMeshFakes(provider: FakeUpstream, options: MeshFakeOptions = {}) {
  const store = makeMemoryMeshStore();
  const vpcs = new Map<string, { readonly id: string; readonly cidr: string }>();
  const tunnels = new Map<string, FakeTunnel>();
  const rules = new Map<string, FakeRule>();
  /** VM provider id -> network id. */
  const vmNetworks = new Map<string, string>();
  const state: {
    mintKey: boolean;
    tunnelCreateStatus: number | null;
    tunnelDeleteStatus: number | null;
    ruleCreateStatus: number | null;
    ruleCreates: number;
    rotations: number;
  } = {
    mintKey: false,
    tunnelCreateStatus: null,
    tunnelDeleteStatus: null,
    ruleCreateStatus: null,
    ruleCreates: 0,
    rotations: 0,
  };
  let hostCounter = 10;
  /** While set, rule creates wait for this promise (a stalled provider call). */
  let ruleHold: Promise<void> | null = null;
  const heldWaiters: Array<() => void> = [];
  let heldCount = 0;

  const tunnelBody = (tunnel: FakeTunnel, privateKey: string) => ({
    id: tunnel.id,
    tunnelId: tunnel.id,
    endpointHost: `tun-${tunnel.id}.beta-vpn.example`,
    endpointPort: 51820,
    serverPublicKey: tunnel.serverPublicKey ?? "c2VydmVyLXB1YmxpYy1rZXktMzItYnl0ZXMtbG9uZyE=",
    clientPublicKey: tunnel.clientPublicKey ?? "bWludGVkLXB1YmxpYy1rZXktMzItYnl0ZXMtbG9uZyE=",
    clientAddressV4: "100.64.0.1/32",
    clientAddressV6: "fd00::1/128",
    routes: tunnel.routes,
    clientConfig: `[Interface]\nPrivateKey = ${privateKey}\nAddress = 100.64.0.1/32\n`,
    clientPrivateKey: privateKey,
    attachments: [{ vpcId: tunnel.vpc, address: tunnel.ipv4, ipv4: tunnel.ipv4, vpcCidr: "", allowedIps: [], createdAt: "2026-10-07T00:00:00Z" }],
    createdAt: "2026-10-07T00:00:00Z",
    updatedAt: "2026-10-07T00:00:00Z",
  });

  /** Answers the networking routes; null for anything else (the next fake answers it). */
  const upstream = async (request: Request): Promise<Response | null> => {
    const url = new URL(request.url);
    if (url.hostname === "cloudflare-dns.com") {
      // DNS over HTTPS for the per-tunnel endpoint names: they all resolve to one gateway.
      const host = url.searchParams.get("name") ?? "";
      return host.endsWith(".beta-vpn.example") ? json({ Status: 0, Answer: [{ name: host, type: 1, TTL: 60, data: "203.0.113.30" }] }) : json({ Status: 3 });
    }
    const path = url.pathname;
    const method = request.method;
    const isMesh =
      path === "/v5/vpcs" ||
      path.startsWith("/v5/vpcs/") ||
      path === "/v5/tunnels" ||
      path.startsWith("/v5/tunnels/") ||
      path === "/v5/firewall/rules" ||
      path.startsWith("/v5/firewall/rules/") ||
      /^\/v5\/vms\/[^/]+\/networks$/u.test(path);
    if (!isMesh) return null;
    const raw = request.body === null ? null : new Uint8Array(await request.clone().arrayBuffer());
    const body: unknown = raw === null || raw.length === 0 ? null : JSON.parse(new TextDecoder().decode(raw));
    provider.calls.push({ method, path, search: url.searchParams, json: body, bytes: raw });
    if (request.headers.get("authorization") !== `Bearer ${UPSTREAM_KEY}`) return json({ message: "bad key" }, 401);
    const fields = typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};

    if (path === "/v5/vpcs" && method === "POST") {
      const id = `vpc-${crypto.randomUUID()}`;
      const cidr = typeof fields["cidr"] === "string" ? fields["cidr"] : "10.0.0.0/24";
      vpcs.set(id, { id, cidr });
      return json({ id, cidr, cidrV6: "fd00:1::/64", createdAt: "2026-10-07T00:00:00Z" });
    }
    const vpcMatch = /^\/v5\/vpcs\/([^/]+)$/u.exec(path);
    if (vpcMatch !== null && method === "GET") {
      const found = vpcs.get(decodeURIComponent(vpcMatch[1] ?? ""));
      return found === undefined ? json({ message: "not found" }, 404) : json({ ...found, cidrV6: "fd00:1::/64", createdAt: "2026-10-07T00:00:00Z" });
    }
    if (vpcMatch !== null && method === "DELETE") {
      const id = decodeURIComponent(vpcMatch[1] ?? "");
      if (!vpcs.has(id)) return json({ message: "not found" }, 404);
      if ([...vmNetworks.values()].includes(id) || [...tunnels.values()].some((tunnel) => tunnel.vpc === id)) return json({ message: "in use" }, 409);
      vpcs.delete(id);
      return new Response(null, { status: 204 });
    }
    if (path === "/v5/tunnels" && method === "POST") {
      if (state.tunnelCreateStatus !== null) return json({ message: "injected failure" }, state.tunnelCreateStatus);
      const attach = Array.isArray(fields["vpcs"]) ? fields["vpcs"][0] : undefined;
      const vpc = typeof attach === "object" && attach !== null && "vpc" in attach && typeof attach.vpc === "string" ? attach.vpc : "";
      if (!vpcs.has(vpc)) return json({ message: "no such network" }, 404);
      const routesIn = Array.isArray(fields["routes"]) ? fields["routes"] : [];
      if (!routesIn.includes("fd00:1::/64")) return json({ code: "CONFLICT", message: "network IPv6 range outside the tunnel's routes" }, 409);
      const routes = Array.isArray(fields["routes"]) ? fields["routes"].filter((route): route is string => typeof route === "string") : [];
      const tunnel: FakeTunnel = {
        id: `tun-${crypto.randomUUID()}`,
        clientPublicKey: typeof fields["clientPublicKey"] === "string" ? fields["clientPublicKey"] : null,
        routes,
        vpc,
        ipv4: `10.128.0.${hostCounter++}`,
      };
      tunnels.set(tunnel.id, tunnel);
      // The provider mints a key when none is supplied; the test switch makes it mint one anyway.
      const minted = tunnel.clientPublicKey === null || state.mintKey ? "bWludGVkLXByaXZhdGUta2V5LTMyLWJ5dGVzLWxvbmch" : "";
      return json(tunnelBody(tunnel, minted));
    }
    const rotateMatch = /^\/v5\/tunnels\/([^/]+)\/rotate-key$/u.exec(path);
    if (rotateMatch !== null && method === "POST") {
      const id = decodeURIComponent(rotateMatch[1] ?? "");
      const tunnel = tunnels.get(id);
      if (tunnel === undefined) return json({ message: "not found" }, 404);
      const clientPublicKey = typeof fields["clientPublicKey"] === "string" ? fields["clientPublicKey"] : null;
      state.rotations += 1;
      const rotated: FakeTunnel = { ...tunnel, clientPublicKey, serverPublicKey: btoa(`rotated-server-key-${String(state.rotations).padStart(13, "0")}`) };
      tunnels.set(id, rotated);
      const minted = clientPublicKey === null || state.mintKey ? "bWludGVkLXByaXZhdGUta2V5LTMyLWJ5dGVzLWxvbmch" : "";
      return json(tunnelBody(rotated, minted));
    }
    const tunnelMatch = /^\/v5\/tunnels\/([^/]+)$/u.exec(path);
    if (tunnelMatch !== null) {
      const id = decodeURIComponent(tunnelMatch[1] ?? "");
      const tunnel = tunnels.get(id);
      if (tunnel === undefined) return json({ message: "not found" }, 404);
      if (method === "GET") return json(tunnelBody(tunnel, ""));
      if (method === "DELETE") {
        if (state.tunnelDeleteStatus !== null) return json({ message: "injected failure" }, state.tunnelDeleteStatus);
        tunnels.delete(id);
        // Rules naming a deleted tunnel go with it.
        for (const [ruleId, rule] of rules) if (rule.source["tunnelId"] === id || rule.destination["tunnelId"] === id) rules.delete(ruleId);
        return new Response(null, { status: 204 });
      }
    }
    if (path === "/v5/firewall/rules" && method === "POST") {
      if (ruleHold !== null) {
        heldCount += 1;
        for (const wake of heldWaiters.splice(0)) wake();
        await ruleHold;
      }
      state.ruleCreates += 1;
      if (state.ruleCreateStatus !== null) return json({ message: "refused" }, state.ruleCreateStatus);
      const source = typeof fields["source"] === "object" && fields["source"] !== null ? Object.fromEntries(Object.entries(fields["source"])) : {};
      const destination =
        typeof fields["destination"] === "object" && fields["destination"] !== null ? Object.fromEntries(Object.entries(fields["destination"])) : {};
      const tunnelId = source["tunnelId"];
      const vmId = destination["vmId"];
      if (typeof tunnelId !== "string" || !tunnels.has(tunnelId)) return json({ message: "no such tunnel" }, 404);
      if (typeof vmId !== "string" || !provider.vms.has(vmId)) return json({ message: "no such vm" }, 404);
      const rule: FakeRule = {
        id: `fwr-${crypto.randomUUID()}`,
        source,
        destination,
        description: typeof fields["description"] === "string" ? fields["description"] : null,
      };
      rules.set(rule.id, rule);
      return json({ ...rule, action: "allow", createdAt: "2026-10-07T00:00:00Z", updatedAt: "2026-10-07T00:00:00Z" });
    }
    const ruleMatch = /^\/v5\/firewall\/rules\/([^/]+)$/u.exec(path);
    if (ruleMatch !== null && method === "DELETE") {
      const id = decodeURIComponent(ruleMatch[1] ?? "");
      if (!rules.delete(id)) return json({ message: "not found" }, 404);
      return new Response(null, { status: 204 });
    }
    const networksMatch = /^\/v5\/vms\/([^/]+)\/networks$/u.exec(path);
    if (networksMatch !== null && method === "PUT") {
      const vmId = decodeURIComponent(networksMatch[1] ?? "");
      if (!provider.vms.has(vmId)) return json({ message: "no such vm" }, 404);
      const list = Array.isArray(fields["networks"]) ? fields["networks"] : [];
      const first = list[0];
      if (first === undefined) {
        vmNetworks.delete(vmId);
        return json({ id: vmId, vpcs: [] });
      }
      const vpc = typeof first === "object" && first !== null && "vpc" in first && typeof first.vpc === "string" ? first.vpc : "";
      if (!vpcs.has(vpc)) return json({ message: "no such network" }, 404);
      vmNetworks.set(vmId, vpc);
      return json({ id: vmId, vpcs: [{ vpc, vpcId: vpc, ipv4: `10.128.0.${hostCounter++}` }] });
    }
    return json({ message: "no route" }, 404);
  };

  const layer = (fetch: (request: Request) => Promise<Response>) =>
    Layer.mergeAll(
      store.layer,
      Layer.succeed(UpstreamMesh, makeUpstreamMesh({ baseUrl: UPSTREAM_URL, apiKey: Redacted.make(UPSTREAM_KEY), environment: "local", fetch })),
      meshConfigLayer({
        experiment: options.experiment ?? true,
        tenantIds: options.tenants ?? ["team_alpha", "team_bravo"],
        ...(options.budgets === undefined ? {} : { budgets: options.budgets }),
      }),
    );

  return {
    upstream,
    layer,
    store,
    vpcs,
    tunnels,
    rules,
    vmNetworks,
    /** The provider mints a private key on the next tunnel creates, even with a client key. */
    mintKeys(on: boolean) {
      state.mintKey = on;
    },
    /** Tunnel creates answer `status` (null: normal). */
    failTunnelCreates(status: number | null) {
      state.tunnelCreateStatus = status;
    },
    /** Tunnel deletes answer `status` (null: normal). */
    failTunnelDeletes(status: number | null) {
      state.tunnelDeleteStatus = status;
    },
    /** Rule creates answer `status` (null: normal). */
    failRuleCreates(status: number | null) {
      state.ruleCreateStatus = status;
    },
    ruleCreateCount: () => state.ruleCreates,
    /** Rule creates stall until the returned function is called. */
    holdRuleCreates(): () => void {
      let release = () => {};
      ruleHold = new Promise<void>((resolve) => {
        release = () => {
          ruleHold = null;
          resolve();
        };
      });
      heldCount = 0;
      return () => release();
    },
    /** Resolves once a rule create is stalled by holdRuleCreates. */
    ruleCreateHeld(): Promise<void> {
      if (heldCount > 0) return Promise.resolve();
      return new Promise<void>((resolve) => heldWaiters.push(resolve));
    },
  };
}

export type MeshFakes = ReturnType<typeof makeMeshFakes>;
