/**
 * The live provider networking client for the mesh experiment (interface:
 * src/upstream/mesh.ts). Imported only from src/upstream/, src/proofs/ and
 * src/index.ts. Provider ids come from minted proofs or from this client's own
 * creates; the provider key stays in live-http.ts.
 */
import { Effect, Layer, Redacted, Schema } from "effect";
import { UpstreamId } from "../lib/ids.ts";
import type { Environment } from "../policy.ts";
import { signedKeysOf } from "../proofs/device-holds-key.ts";
import { endpointOf, ruleIdOf } from "../proofs/same-mesh.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp, proofSegment } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";
import { upstreamName } from "./naming.ts";
import { type CreatedNetwork, type CreatedTunnel, type TunnelInfo, UpstreamMesh, type UpstreamMeshService } from "./mesh.ts";

const NetworkBody = Schema.Struct({ id: UpstreamId, cidr: Schema.optional(Schema.NullOr(Schema.String)) });

const TunnelBody = Schema.Struct({
  id: Schema.optional(Schema.NullOr(Schema.String)),
  tunnelId: Schema.optional(Schema.NullOr(Schema.String)),
  endpointHost: Schema.optional(Schema.NullOr(Schema.String)),
  endpointPort: Schema.Number,
  serverPublicKey: Schema.String,
  clientAddressV4: Schema.String,
  routes: Schema.Array(Schema.String),
  clientConfig: Schema.optional(Schema.String),
  clientPrivateKey: Schema.optional(Schema.NullOr(Schema.String)),
  attachments: Schema.optional(Schema.Array(Schema.Struct({ ipv4: Schema.optional(Schema.NullOr(Schema.String)) }))),
});
type TunnelBody = typeof TunnelBody.Type;

const VmNetworks = Schema.Struct({
  vpcs: Schema.optional(Schema.Array(Schema.Struct({ ipv4: Schema.optional(Schema.NullOr(Schema.String)) }))),
  networks: Schema.optional(Schema.Array(Schema.Struct({ ipv4: Schema.optional(Schema.NullOr(Schema.String)) }))),
});

const RuleBody = Schema.Struct({ id: Schema.String });

const decodeAs =
  <A, I>(schema: Schema.Schema<A, I>, operation: string) =>
  (body: unknown): Effect.Effect<A, UpstreamError> =>
    Schema.decodeUnknown(schema)(body).pipe(Effect.mapError(() => new UpstreamError({ operation, status: null })));

/** True when the provider minted a private key (it must never: the device holds its own). */
export const carriesPrivateKey = (body: TunnelBody): boolean =>
  (typeof body.clientPrivateKey === "string" && body.clientPrivateKey.trim().length > 0) ||
  /^[ \t]*PrivateKey[ \t]*=[ \t]*\S/mu.test(body.clientConfig ?? "");

const infoOf = (body: TunnelBody): TunnelInfo => ({
  endpointHost: body.endpointHost ?? "",
  endpointPort: body.endpointPort,
  serverPublicKey: body.serverPublicKey,
  interfaceAddress: body.clientAddressV4,
  meshAddress: body.attachments?.[0]?.ipv4 ?? null,
  allowedIps: body.routes,
});

const DnsAnswer = Schema.Struct({
  Status: Schema.Number,
  Answer: Schema.optional(Schema.Array(Schema.Struct({ type: Schema.Number, data: Schema.String }))),
});

const IPV4 = /^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$/u;

/**
 * The provider names each tunnel's endpoint after the tunnel's provider id
 * (and the provider). Devices get the address instead, so neither reaches a
 * client; every endpoint name resolves to the same gateway (DESIGN.md 1.4
 * Q16), and WireGuard routes by key, not by name. Resolved with DNS over
 * HTTPS; no answer is a failure, never a fallback to the name.
 */
const resolveEndpoint = (send: (request: Request) => Promise<Response>, host: string): Effect.Effect<string, UpstreamError> => {
  if (IPV4.test(host)) return Effect.succeed(host);
  return Effect.tryPromise({
    try: async () => {
      const url = new URL("https://cloudflare-dns.com/dns-query");
      url.searchParams.set("name", host);
      url.searchParams.set("type", "A");
      const response = await send(new Request(url, { headers: { accept: "application/dns-json" }, signal: AbortSignal.timeout(5000) }));
      if (!response.ok) throw new Error(`dns ${response.status}`);
      const body: unknown = await response.json();
      return body;
    },
    catch: () => new UpstreamError({ operation: "resolveEndpoint", status: null }),
  }).pipe(
    Effect.flatMap(decodeAs(DnsAnswer, "resolveEndpoint")),
    Effect.flatMap((answer) => {
      const address = (answer.Answer ?? []).find((record) => record.type === 1 && IPV4.test(record.data))?.data;
      return answer.Status === 0 && address !== undefined ? Effect.succeed(address) : Effect.fail(new UpstreamError({ operation: "resolveEndpoint", status: null }));
    }),
  );
};

const tunnelIdOf = (body: TunnelBody): string | null => body.tunnelId ?? body.id ?? null;

const path = (id: string) => encodeURIComponent(id);

export function makeUpstreamMesh(config: UpstreamConfig): UpstreamMeshService {
  const http = makeUpstreamHttp(config);
  const send = config.fetch ?? ((request: Request) => fetch(request));
  const withAddress = (info: TunnelInfo) =>
    Effect.map(resolveEndpoint(send, info.endpointHost), (endpointHost): TunnelInfo => ({ ...info, endpointHost }));
  const networks = new WeakSet<CreatedNetwork>();
  const tunnels = new WeakSet<CreatedTunnel>();

  const deleteTunnelById = (operation: string, id: string) =>
    http.json(operation, "DELETE", `/v5/tunnels/${path(id)}`).pipe(Effect.asVoid);

  return {
    createNetwork: (mesh, _proofs, options) =>
      http
        .json("createNetwork", "POST", "/v5/vpcs", { displayName: upstreamName(config.environment, options.tenantId, mesh.value), cidr: options.cidr })
        .pipe(
          Effect.flatMap(decodeAs(NetworkBody, "createNetwork")),
          Effect.map((body) => {
            const created: CreatedNetwork = Object.freeze({ upstreamId: body.id, cidr: body.cidr ?? options.cidr });
            networks.add(created);
            return created;
          }),
        ),
    discardCreatedNetwork: (created) =>
      networks.has(created)
        ? http.json("discardCreatedNetwork", "DELETE", `/v5/vpcs/${path(created.upstreamId)}`).pipe(Effect.asVoid)
        : Effect.fail(new UpstreamError({ operation: "discardCreatedNetwork", status: null })),
    deleteNetwork: (_mesh, { owns }) => http.json("deleteNetwork", "DELETE", `/v5/vpcs/${proofSegment(owns)}`).pipe(Effect.asVoid),

    createTunnel: (_mesh, { owns, holds }, options) =>
      Effect.gen(function* () {
        // The provider refuses a tunnel whose routes miss any range of the network,
        // and every network also has an IPv6 /64 (assigned by the provider).
        const network = yield* http
          .json("getNetwork", "GET", `/v5/vpcs/${proofSegment(owns)}`)
          .pipe(Effect.flatMap(decodeAs(Schema.Struct({ cidrV6: Schema.optional(Schema.NullOr(Schema.String)) }), "getNetwork")));
        const routes = network.cidrV6 ? [...options.routes, network.cidrV6] : [...options.routes];
        const raw = yield* http.json("createTunnel", "POST", "/v5/tunnels", {
          // Always our key: omitting it would make the provider mint one, and that key would leave the device boundary.
          clientPublicKey: signedKeysOf(holds).wgPublicKey,
          displayName: upstreamName(config.environment, options.tenantId, options.deviceId),
          routes,
          vpcs: [{ vpc: upstreamIdOf(owns) }],
        });
        const body = yield* decodeAs(TunnelBody, "createTunnel")(raw);
        const id = tunnelIdOf(body);
        if (id === null) return yield* Effect.fail(new UpstreamError({ operation: "createTunnel", status: null }));
        if (carriesPrivateKey(body)) {
          // Fail closed: the tunnel must not exist with a key the device did not make.
          yield* deleteTunnelById("createTunnel.mintedKey", id).pipe(Effect.ignore);
          return yield* Effect.fail(new UpstreamError({ operation: "createTunnel.mintedKey", status: null }));
        }
        const info = yield* withAddress(infoOf(body)).pipe(
          // Without an address the device cannot use the tunnel: undo it.
          Effect.tapError(() => deleteTunnelById("createTunnel.resolve", id).pipe(Effect.ignore)),
        );
        const created: CreatedTunnel = Object.freeze({ upstreamId: UpstreamId.make(id), info });
        tunnels.add(created);
        return created;
      }),
    discardCreatedTunnel: (created) =>
      tunnels.has(created)
        ? deleteTunnelById("discardCreatedTunnel", created.upstreamId)
        : Effect.fail(new UpstreamError({ operation: "discardCreatedTunnel", status: null })),
    getTunnel: (_tunnel, { owns }) =>
      http
        .json("getTunnel", "GET", `/v5/tunnels/${proofSegment(owns)}`)
        .pipe(Effect.flatMap(decodeAs(TunnelBody, "getTunnel")), Effect.map(infoOf), Effect.flatMap(withAddress)),
    rotateTunnelKey: (_device, { owns, holds }) =>
      Effect.gen(function* () {
        const raw = yield* http.json("rotateTunnelKey", "POST", `/v5/tunnels/${proofSegment(owns)}/rotate-key`, {
          // Always the signed key: without one the provider would mint a key pair and hold the private half.
          clientPublicKey: signedKeysOf(holds).wgPublicKey,
        });
        const body = yield* decodeAs(TunnelBody, "rotateTunnelKey")(raw);
        // Fail closed: a minted private key is dropped here and never returned.
        if (carriesPrivateKey(body)) return yield* Effect.fail(new UpstreamError({ operation: "rotateTunnelKey.mintedKey", status: null }));
        return yield* withAddress(infoOf(body));
      }),
    deleteDeviceTunnel: (_device, { owns }) => http.json("deleteTunnel", "DELETE", `/v5/tunnels/${proofSegment(owns)}`).pipe(Effect.asVoid),

    attachVm: (_mesh, _vm, { ownsMesh, ownsVm }) =>
      http
        .json("attachVm", "PUT", `/v5/vms/${proofSegment(ownsVm)}/networks`, { networks: [{ vpc: upstreamIdOf(ownsMesh) }] })
        .pipe(
          Effect.flatMap(decodeAs(VmNetworks, "attachVm")),
          Effect.map((body) => ({ ipv4: (body.vpcs ?? body.networks ?? [])[0]?.ipv4 ?? null })),
        ),
    detachVm: (_vm, { ownsVm }) => http.json("detachVm", "PUT", `/v5/vms/${proofSegment(ownsVm)}/networks`, { networks: [] }).pipe(Effect.asVoid),

    createRule: (mesh, _source, _destination, proofs, matcher) =>
      http
        .json("createRule", "POST", "/v5/firewall/rules", {
          action: "allow",
          source: { tunnelId: endpointOf(proofs.source) },
          destination: {
            vmId: endpointOf(proofs.destination),
            ...(matcher.protocol === null ? {} : { protocol: matcher.protocol }),
            ...(matcher.port === null ? {} : { port: matcher.port }),
          },
          // The rule names this mesh so the provider-side view is attributable.
          description: `cmux:mesh:${mesh.value}`,
        })
        .pipe(
          Effect.flatMap(decodeAs(RuleBody, "createRule")),
          Effect.map((body) => ({ upstreamRuleId: body.id })),
        ),
    deleteRule: (rule) => http.json("deleteRule", "DELETE", `/v5/firewall/rules/${path(ruleIdOf(rule))}`).pipe(Effect.asVoid),
  };
}

export const upstreamMeshLayer = (config: { readonly baseUrl: string; readonly apiKey: string; readonly environment: Environment }): Layer.Layer<UpstreamMesh> =>
  Layer.succeed(UpstreamMesh, makeUpstreamMesh({ baseUrl: config.baseUrl, apiKey: Redacted.make(config.apiKey), environment: config.environment }));
