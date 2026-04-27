// Authenticated REST facade over the VM control plane. Native clients use this surface so
// provider credentials stay behind server-side ownership checks.

import {
  DEFAULT_E2B_WS_TEMPLATE,
  DEFAULT_FREESTYLE_SNAPSHOT_ID,
  defaultProviderId,
  type ProviderId,
} from "../../../services/vms/drivers";
import {
  isVmBillingError,
  isVmCreateFailedError,
  isVmCreateCreditsInsufficientError,
  isVmCreateInProgressError,
  isVmLimitExceededError,
} from "../../../services/vms/errors";
import { resolveVmEntitlements } from "../../../services/vms/entitlements";
import {
  jsonResponse,
  withAuthedVmApiRoute,
} from "../../../services/vms/routeHelpers";
import {
  createVm,
  listUserVms,
  runVmWorkflow,
} from "../../../services/vms/workflows";
import { setSpanAttributes } from "../../../services/telemetry";

export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm",
    { "cmux.vm.operation": "list" },
    "/api/vm GET failed",
    async ({ user, span }) => {
      const entries = await runVmWorkflow(listUserVms(user.id));
      setSpanAttributes(span, { "cmux.vm.count": entries.length });
      // REST adapter: expose `id` at the top level so existing CLI + curl users don't need to
      // learn the new `providerVmId` field name. Swift CLI reads `vm["id"]`.
      const vms = entries.map((entry) => ({
        id: entry.providerVmId,
        provider: entry.provider,
        image: entry.image,
        createdAt: entry.createdAt,
      }));
      return jsonResponse({ vms });
    },
  );
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm",
    { "cmux.vm.operation": "create" },
    "/api/vm POST failed",
    async ({ user, span }) => {
      // Runtime-validate the payload before we call a paid provider. An invalid `provider`
      // (client sending `"aws"` or `"docker"`) previously slipped past the type cast and
      // surfaced as a 500 from the driver after provisioning had already half-succeeded.
      let body: { image?: string; provider?: ProviderId };
      try {
        // Allow callers to send no body at all — the handler already falls through to
        // default provider/image, so a bare `curl -X POST /api/vm` should create a default
        // VM. Previously request.json() threw on an empty body and the whole request came
        // back as 400 "invalid JSON body". Distinguish empty-body from literal-`null`:
        // empty is a default-create, `null` is malformed input and should 400.
        const rawText = await request.text();
        const bodyWasEmpty = rawText.length === 0;
        const raw = bodyWasEmpty ? undefined : JSON.parse(rawText);
        if (!bodyWasEmpty) {
          if (raw === null) {
            throw new TypeError("body must be a JSON object, got null");
          }
          if (typeof raw !== "object" || Array.isArray(raw)) {
            throw new TypeError("body must be a JSON object");
          }
        }
        const candidate = (raw ?? {}) as Record<string, unknown>;
        if (candidate.image !== undefined && typeof candidate.image !== "string") {
          return jsonResponse({ error: "`image` must be a string when provided" }, 400);
        }
        if (candidate.provider !== undefined) {
          if (typeof candidate.provider !== "string") {
            return jsonResponse({ error: "`provider` must be a string when provided" }, 400);
          }
          if (candidate.provider !== "e2b" && candidate.provider !== "freestyle") {
            return jsonResponse(
              { error: `provider must be "e2b" or "freestyle", got ${JSON.stringify(candidate.provider)}` },
              400,
            );
          }
        }
        body = {
          image: typeof candidate.image === "string" ? candidate.image : undefined,
          provider: candidate.provider as ProviderId | undefined,
        };
      } catch {
        return jsonResponse({ error: "invalid JSON body" }, 400);
      }
      const provider = body.provider ?? defaultProviderId();
      const image = body.image ?? defaultImageFor(provider);
      // Idempotency-Key is standard HTTP; we also accept x-cmux-idempotency-key for CLI
      // callers that don't know about RFC-style keys. Trim + clamp to a reasonable length
      // so we don't store unbounded idempotency metadata.
      const rawKey = (
        request.headers.get("idempotency-key") ||
        request.headers.get("x-cmux-idempotency-key") ||
        ""
      ).trim();
      const idempotencyKey = rawKey ? rawKey.slice(0, 128) : undefined;
      setSpanAttributes(span, {
        "cmux.vm.provider": provider,
        "cmux.vm.image_set": image.length > 0,
        "cmux.idempotency_key_set": !!idempotencyKey,
      });

      const entitlements = resolveVmEntitlements(user);
      setSpanAttributes(span, {
        "cmux.billing.team_id_set": !!entitlements.billingTeamId,
        "cmux.billing.customer_type": user.billingCustomerType,
        "cmux.billing.plan_id": entitlements.planId,
        "cmux.vm.max_active": entitlements.maxActiveVms,
      });

      let created;
      try {
        created = await runVmWorkflow(createVm({
          userId: user.id,
          billingCustomerType: user.billingCustomerType,
          billingTeamId: entitlements.billingTeamId,
          billingPlanId: entitlements.planId,
          maxActiveVms: entitlements.maxActiveVms,
          image,
          provider,
          idempotencyKey,
        }));
      } catch (err) {
        if (isVmCreateInProgressError(err)) {
          return jsonResponse({ error: "vm create already in progress" }, 409);
        }
        if (isVmCreateFailedError(err)) {
          return jsonResponse({ error: err.message }, 500);
        }
        if (isVmLimitExceededError(err)) {
          return jsonResponse({
            error: "vm_active_limit_exceeded",
            limit: err.limit,
            billingTeamId: err.billingTeamId,
          }, 402);
        }
        if (isVmCreateCreditsInsufficientError(err)) {
          return jsonResponse({
            error: "vm_create_credits_insufficient",
            itemId: err.itemId,
            amount: err.amount,
          }, 402);
        }
        if (isVmBillingError(err)) {
          return jsonResponse({ error: "vm_billing_unavailable" }, 503);
        }
        throw err;
      }
      setSpanAttributes(span, { "cmux.vm.id": created.providerVmId });
      return jsonResponse({
        id: created.providerVmId,
        provider: created.provider,
        image: created.image,
        createdAt: created.createdAt,
      });
    },
  );
}

function defaultImageFor(provider: ProviderId): string {
  if (provider === "e2b") {
    return process.env.E2B_CMUXD_WS_TEMPLATE ??
      DEFAULT_E2B_WS_TEMPLATE;
  }
  return process.env.FREESTYLE_SANDBOX_SNAPSHOT?.trim() || DEFAULT_FREESTYLE_SNAPSHOT_ID;
}
