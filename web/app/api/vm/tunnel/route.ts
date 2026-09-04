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
  listVmTunnels,
  readVmTunnel,
  revokeVmTunnel,
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

      setSpanAttributes(span, {
        "cmux.vm.provider": provider.id,
        "cmux.vm.tunnel.device": deviceFingerprint,
      });

      const tunnel = await runVmWorkflow(enrollVmTunnel({
        userId: user.id,
        provider: provider.id,
        deviceFingerprint,
        deviceName: deviceName(body),
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
        const tunnels = await runVmWorkflow(listVmTunnels({ userId: user.id }));
        return jsonResponse({ tunnels });
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
      let deviceFingerprint: string | undefined;
      try {
        deviceFingerprint = optionalClientIdentifier(
          url.searchParams.get("deviceFingerprint") ?? body.deviceFingerprint ?? body.device_fingerprint,
          "deviceFingerprint",
        );
      } catch (err) {
        return invalidDeviceFingerprint(err);
      }
      if (!deviceFingerprint) return missingDeviceFingerprint();

      const provider = providerFromRequest(request, body);
      if (!provider.ok) return provider.response;
      setSpanAttributes(span, {
        "cmux.vm.provider": provider.id,
        "cmux.vm.tunnel.device": deviceFingerprint,
      });
      const result = await runVmWorkflow(revokeVmTunnel({
        userId: user.id,
        provider: provider.id,
        deviceFingerprint,
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

function tunnelPayload(tunnel: VmTunnelDescriptor) {
  return {
    tunnelId: tunnel.tunnelId,
    provider: tunnel.provider,
    deviceFingerprint: tunnel.deviceFingerprint,
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
