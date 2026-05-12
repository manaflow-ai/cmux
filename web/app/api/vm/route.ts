// Authenticated REST facade over the VM control plane. Native clients use this surface so
// provider credentials stay behind server-side ownership checks.

import {
  defaultProviderId,
  type ProviderId,
} from "../../../services/vms/drivers";
import { assertVmCreateEnabled } from "../../../services/vms/config";
import {
  isVmBillingError,
  isVmCreateDisabledError,
  isVmCreateFailedError,
  isVmCreateCreditsInsufficientError,
  isVmCreateInProgressError,
  isVmImageConfigError,
  isVmLimitExceededError,
} from "../../../services/vms/errors";
import {
  isVmBillingTeamResolutionError,
  resolveVmEntitlements,
} from "../../../services/vms/entitlements";
import { resolveVmImage } from "../../../services/vms/images/resolver";
import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
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
      let billingTeamId: string | null = null;
      const requestedBillingTeamId = requestedVmTeamIdFromRequest(request);
      try {
        if (requestedBillingTeamId || user.billingCustomerType === "team") {
          const entitlements = resolveVmEntitlements(user, process.env, {
            requestedBillingTeamId,
            requireTeam: false,
          });
          billingTeamId = entitlements.billingTeamId;
          setSpanAttributes(span, {
            "cmux.billing.team_id_set": !!billingTeamId,
            "cmux.billing.customer_type": entitlements.billingCustomerType,
            "cmux.billing.plan_id": entitlements.planId,
          });
        }
      } catch (err) {
        if (isVmBillingTeamResolutionError(err)) {
          return jsonResponse({ error: err.code, reason: err.message }, err.status);
        }
        throw err;
      }

      const entries = await runVmWorkflow(listUserVms(user.id, billingTeamId));
      setSpanAttributes(span, { "cmux.vm.count": entries.length });
      // REST adapter: expose `id` at the top level so existing CLI + curl users don't need to
      // learn the new `providerVmId` field name. Swift CLI reads `vm["id"]`.
      const vms = entries.map((entry) => ({
        id: entry.providerVmId,
        provider: entry.provider,
        image: entry.image,
        imageVersion: entry.imageVersion,
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
      let body: { image?: string; provider?: ProviderId; billingTeamId?: string };
      try {
        // Allow callers to send no body at all. The handler already falls through to
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
        const bodyBillingTeamId = candidate.billingTeamId ?? candidate.teamId;
        if (bodyBillingTeamId !== undefined && typeof bodyBillingTeamId !== "string") {
          return jsonResponse({ error: "`teamId` must be a string when provided" }, 400);
        }
        body = {
          image: typeof candidate.image === "string" ? candidate.image : undefined,
          provider: candidate.provider as ProviderId | undefined,
          billingTeamId: typeof bodyBillingTeamId === "string" ? bodyBillingTeamId.trim() : undefined,
        };
      } catch {
        return jsonResponse({ error: "invalid JSON body" }, 400);
      }
      const provider = body.provider ?? defaultProviderId();
      let imageSelection;
      try {
        assertVmCreateEnabled(provider);
        imageSelection = resolveVmImage(provider, body.image);
      } catch (err) {
        if (isVmCreateDisabledError(err)) {
          return jsonResponse({
            error: "vm_create_disabled",
            provider: err.provider,
            reason: err.reason,
          }, 503);
        }
        if (isVmImageConfigError(err)) {
          const payload: {
            error: "vm_image_config_error";
            provider: ProviderId;
            image?: string;
            envVar?: string;
            reason: string;
          } = {
            error: "vm_image_config_error",
            provider: err.provider,
            envVar: err.envVar,
            reason: err.reason,
          };
          if (err.image !== undefined) payload.image = err.image;
          return jsonResponse(payload, 503);
        }
        throw err;
      }
      const image = imageSelection.image;
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
        "cmux.vm.image_version": imageSelection.imageVersion,
        "cmux.vm.image_manifest": !!imageSelection.manifestEntry,
        "cmux.idempotency_key_set": !!idempotencyKey,
      });

      const requestedBillingTeamId = body.billingTeamId || requestedVmTeamIdFromRequest(request);
      let entitlements;
      try {
        entitlements = resolveVmEntitlements(user, process.env, {
          requestedBillingTeamId,
          requireTeam: true,
        });
      } catch (err) {
        if (isVmBillingTeamResolutionError(err)) {
          return jsonResponse({ error: err.code, reason: err.message }, err.status);
        }
        throw err;
      }
      setSpanAttributes(span, {
        "cmux.billing.team_id_set": !!entitlements.billingTeamId,
        "cmux.billing.customer_type": entitlements.billingCustomerType,
        "cmux.billing.plan_id": entitlements.planId,
        "cmux.billing.requested_team_id_set": !!requestedBillingTeamId,
        "cmux.vm.max_active": entitlements.maxActiveVms,
      });

      let created;
      try {
        created = await runVmWorkflow(createVm({
          userId: user.id,
          billingCustomerType: entitlements.billingCustomerType,
          billingTeamId: entitlements.billingTeamId,
          billingPlanId: entitlements.planId,
          maxActiveVms: entitlements.maxActiveVms,
          image,
          imageVersion: imageSelection.imageVersion,
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
        imageVersion: created.imageVersion,
        createdAt: created.createdAt,
      });
    },
  );
}
