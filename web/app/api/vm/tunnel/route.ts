import { defaultProviderId, isProviderId } from "../../../../services/vms/drivers";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";
import {
  enrollVmTunnel,
  isWireGuardPublicKey,
  listVmAccessGrants,
  listVmTunnels,
  readVmTunnel,
  revokeVmAccessGrant,
  runVmWorkflow,
  type VmTunnelDescriptor,
} from "../../../../services/vms/workflows";
import {
  optionalClientIdentifier,
  optionalString,
  parseLenientObjectBody,
} from "../../../../services/vms/routeInput";

/**
 * The account's WireGuard tunnels: how a user's own computer becomes a member
 * of the private network their Cloud VMs live on.
 *
 * `POST` enrolls the calling computer and returns a complete `wg-quick` config
 * whose `PrivateKey` line is blank — the caller generated that key and keeps
 * it. Enrolling is idempotent per device, so clients call it on every launch
 * rather than remembering whether they have enrolled; a public key that does
 * not match the record rotates the existing tunnel's keys in place, keeping the
 * device's address on the network stable.
 *
 * This route is deliberately not gated behind the Pro paywall that machine
 * creation uses. It provisions no paid resource, and an account whose
 * subscription lapsed still needs to reach machines it already owns in order to
 * get data off them.
 */

/** Provider display names are short; a long one is the caller's mistake, not a reason to fail. */
const MAX_DEVICE_NAME_LENGTH = 63;

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/tunnel",
    { "cmux.vm.operation": "enroll_tunnel" },
    "/api/vm/tunnel failed",
    async ({ user, span }) => {
      const body = await parseLenientObjectBody(request);
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;

      const provider = providerFromRequest(request, body);
      if (!provider.ok) return provider.response;

      const clientPublicKey = optionalString(body.clientPublicKey ?? body.client_public_key);
      if (!clientPublicKey || !isWireGuardPublicKey(clientPublicKey)) {
        return vmErrorResponse({
          error: "vm_tunnel_invalid_key",
          status: 400,
          message: "clientPublicKey must be a base64-encoded 32-byte WireGuard public key.",
          action:
            "Generate a Curve25519 keypair on this computer, keep the private half, and send only " +
            "the base64 public key. `wg genkey | tee private.key | wg pubkey` produces one.",
          phase: "network",
          details: { field: "clientPublicKey" },
        });
      }

      let deviceFingerprint: string | undefined;
      try {
        deviceFingerprint = optionalClientIdentifier(
          body.deviceFingerprint ?? body.device_fingerprint,
          "deviceFingerprint",
        );
      } catch (err) {
        return invalidDeviceFingerprint(err);
      }
      if (!deviceFingerprint) return missingDeviceFingerprint();
      let deviceId: string | undefined;
      try {
        deviceId = optionalClientIdentifier(body.deviceId ?? body.device_id, "deviceId");
      } catch (err) {
        return invalidDeviceFingerprint(err);
      }
      if (!deviceId) return missingDeviceId();
      const tunnelPurpose = parseTunnelPurpose(body.tunnelPurpose ?? body.tunnel_purpose);
      if (!tunnelPurpose) return invalidTunnelPurpose();

      setSpanAttributes(span, {
        "cmux.vm.provider": provider.id,
        "cmux.vm.tunnel.device": deviceFingerprint,
      });

      const tunnel = await runVmWorkflow(enrollVmTunnel({
        userId: user.id,
        provider: provider.id,
        deviceId,
        deviceFingerprint,
        tunnelPurpose,
        deviceName: deviceName(body),
        modelIdentifier: boundedMetadata(body.modelIdentifier ?? body.model_identifier),
        osVersion: boundedMetadata(body.osVersion ?? body.os_version),
        architecture: boundedMetadata(body.architecture),
        cmuxVersion: boundedMetadata(body.cmuxVersion ?? body.cmux_version),
        cmuxBuild: boundedMetadata(body.cmuxBuild ?? body.cmux_build),
        cmuxChannel: boundedMetadata(body.cmuxChannel ?? body.cmux_channel),
        stackSessionId: stackSessionId(request),
        clientPublicKey,
      }));
      setSpanAttributes(span, {
        "cmux.vm.tunnel.id": tunnel.tunnelId,
        "cmux.vm.tunnel.created": tunnel.created,
        "cmux.vm.tunnel.rotated": tunnel.rotated,
      });
      return jsonResponse(tunnelPayload(tunnel));
    },
  );
}

/**
 * One computer's tunnel with `?deviceFingerprint=`, or the account's enrolled
 * computers without it. The list carries no config — reading it must not be a
 * way to collect other devices' access material.
 */
export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/tunnel",
    { "cmux.vm.operation": "get_tunnel" },
    "/api/vm/tunnel failed",
    async ({ user, span }) => {
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;

      const url = new URL(request.url);
      let deviceFingerprint: string | undefined;
      try {
        deviceFingerprint = optionalClientIdentifier(
          url.searchParams.get("deviceFingerprint"),
          "deviceFingerprint",
        );
      } catch (err) {
        return invalidDeviceFingerprint(err);
      }

      if (!deviceFingerprint) {
        const [devices, tunnels] = await Promise.all([
          runVmWorkflow(listVmAccessGrants({ userId: user.id })),
          runVmWorkflow(listVmTunnels({ userId: user.id })),
        ]);
        return jsonResponse({ devices, tunnels });
      }

      const provider = providerFromRequest(request, {});
      if (!provider.ok) return provider.response;
      setSpanAttributes(span, {
        "cmux.vm.provider": provider.id,
        "cmux.vm.tunnel.device": deviceFingerprint,
      });
      const tunnel = await runVmWorkflow(readVmTunnel({
        userId: user.id,
        provider: provider.id,
        deviceFingerprint,
        tunnelPurpose: parseTunnelPurpose(url.searchParams.get("tunnelPurpose")) ?? "browser",
      }));
      return jsonResponse(tunnelPayload(tunnel));
    },
  );
}

/** Unenroll a computer. The provider tunnel is deleted, so its config stops working at once. */
export async function DELETE(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/tunnel",
    { "cmux.vm.operation": "revoke_tunnel" },
    "/api/vm/tunnel failed",
    async ({ user, span }) => {
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;

      const url = new URL(request.url);
      const body = await parseLenientObjectBody(request);
      let deviceId: string | undefined;
      try {
        deviceId = optionalClientIdentifier(
          url.searchParams.get("deviceId") ?? body.deviceId ?? body.device_id,
          "deviceId",
        );
      } catch (err) {
        return invalidDeviceFingerprint(err);
      }
      const accessGrantId = optionalString(
        url.searchParams.get("accessGrantId") ?? body.accessGrantId ?? body.access_grant_id,
      );
      if (!deviceId && !accessGrantId) return missingDeviceId();
      setSpanAttributes(span, {
        "cmux.vm.access.device": deviceId ?? "by-grant-id",
      });
      const result = await runVmWorkflow(revokeVmAccessGrant({
        userId: user.id,
        accessGrantId: accessGrantId ?? undefined,
        deviceId,
      }));
      return jsonResponse(result);
    },
  );
}

type ProviderResult =
  | { readonly ok: true; readonly id: ReturnType<typeof defaultProviderId> }
  | { readonly ok: false; readonly response: Response };

/**
 * Which provider's network to enroll into. Networks are per-provider, so this
 * has to be explicit rather than "whichever machine you have" — but in practice
 * every caller takes the deployment default and the override exists for the
 * same rollback reasons the rest of the VM API has one.
 */
function providerFromRequest(request: Request, body: Record<string, unknown>): ProviderResult {
  const raw = optionalString(body.provider) ?? new URL(request.url).searchParams.get("provider");
  if (!raw) return { ok: true, id: defaultProviderId() };
  if (isProviderId(raw)) return { ok: true, id: raw };
  return {
    ok: false,
    response: vmErrorResponse({
      error: "vm_invalid_provider",
      status: 400,
      message: "Unsupported Cloud VM service override.",
      action: "Omit `provider` to use the default Cloud VM service.",
      phase: "network",
      details: { field: "provider" },
    }),
  };
}

function deviceName(body: Record<string, unknown>): string | null {
  const raw = optionalString(body.deviceName ?? body.device_name);
  return raw ? raw.slice(0, MAX_DEVICE_NAME_LENGTH) : null;
}

function boundedMetadata(value: unknown): string | null {
  return optionalString(value)?.slice(0, 128) ?? null;
}

function parseTunnelPurpose(value: unknown): "terminal" | "browser" | null {
  const raw = optionalString(value);
  return raw === "terminal" || raw === "browser" ? raw : null;
}

function stackSessionId(request: Request): string | null {
  const authorization = request.headers.get("authorization");
  if (!authorization?.toLowerCase().startsWith("bearer ")) return null;
  const token = authorization.slice("bearer ".length).trim();
  const payload = token.split(".")[1];
  if (!payload) return null;
  try {
    const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
    const decoded = JSON.parse(Buffer.from(normalized, "base64").toString("utf8"));
    return optionalClientIdentifier(decoded.refresh_token_id, "stackSessionId") ?? null;
  } catch {
    return null;
  }
}

function tunnelPayload(tunnel: VmTunnelDescriptor) {
  return {
    accessGrantId: tunnel.accessGrantId,
    tunnelId: tunnel.tunnelId,
    provider: tunnel.provider,
    deviceFingerprint: tunnel.deviceFingerprint,
    tunnelPurpose: tunnel.tunnelPurpose,
    deviceName: tunnel.deviceName,
    clientConfig: tunnel.clientConfig,
    clientPublicKey: tunnel.clientPublicKey,
    serverPublicKey: tunnel.serverPublicKey,
    endpointHost: tunnel.endpointHost,
    endpointPort: tunnel.endpointPort,
    routes: [...tunnel.routes],
    address: { ipv4: tunnel.addressV4, ipv6: tunnel.addressV6 },
    network: tunnel.network,
    created: tunnel.created,
    rotated: tunnel.rotated,
  };
}

function invalidDeviceFingerprint(err: unknown): Response {
  return vmErrorResponse({
    error: "invalid_request",
    status: 400,
    message: err instanceof Error ? err.message : "Invalid Cloud VM tunnel request.",
    action: "Send a stable per-installation deviceFingerprint of 1-128 URL-safe characters.",
    phase: "network",
    details: { field: "deviceFingerprint" },
  });
}

function missingDeviceFingerprint(): Response {
  return vmErrorResponse({
    error: "invalid_request",
    status: 400,
    message: "deviceFingerprint is required.",
    action:
      "Send a stable per-installation deviceFingerprint so this computer keeps the same address " +
      "on the network across launches.",
    phase: "network",
    details: { field: "deviceFingerprint" },
  });
}

function missingDeviceId(): Response {
  return vmErrorResponse({
    error: "invalid_request",
    status: 400,
    message: "deviceId is required.",
    action: "Send this Mac's stable Cloud access device ID.",
    phase: "network",
    details: { field: "deviceId" },
  });
}

function invalidTunnelPurpose(): Response {
  return vmErrorResponse({
    error: "invalid_request",
    status: 400,
    message: "tunnelPurpose must be terminal or browser.",
    action: "Use terminal for the user-space peer or browser for the Network Extension peer.",
    phase: "network",
    details: { field: "tunnelPurpose" },
  });
}
