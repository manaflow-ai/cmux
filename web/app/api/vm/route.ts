// Authenticated REST facade over the VM control plane. Native clients use this surface so
// provider credentials stay behind server-side ownership checks.

import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../services/vms/auth";
import { defaultProviderId } from "../../../services/vms/drivers";
import { assertVmCreateEnabled } from "../../../services/vms/config";
import {
  isVmCreateDisabledError,
  isVmImageConfigError,
} from "../../../services/vms/errors";
import {
  defaultMemoryMbForPlan,
  isVmBillingTeamResolutionError,
  isVmProGateBlocked,
  maxMemoryMbForPlan,
  resolveVmEntitlements,
} from "../../../services/vms/entitlements";
import {
  imageUsesBakedFreestyleSignedAdmin,
  resolveVmImage,
} from "../../../services/vms/images/resolver";
import { reconcileProPlanMetadata } from "../../../services/billing/pro";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import {
  jsonResponse,
  requestedVmTeamIdFromRequest,
  vmCreateWorkflowErrorResponse,
  vmErrorResponse,
  vmWorkflowErrorResponse,
  withAuthedVmApiRoute,
  vmRequiresProResponse,
} from "../../../services/vms/routeHelpers";
import {
  parseVmCreateBody,
  vmInvalidTeamIdResponse,
} from "../../../services/vms/requestSchemas";
import {
  createVm,
  listUserVms,
  runVmWorkflow,
} from "../../../services/vms/workflows";
import { recordSpanError, setSpanAttributes } from "../../../services/telemetry";
import {
  measureVmAsync,
  measureVmSync,
  VmTimingRecorder,
} from "../../../services/vms/timings";
import { authProviderErrorResponse } from "../../../services/vms/authErrors";


export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm",
    { "cmux.vm.operation": "list" },
    "/api/vm GET failed",
    async ({ user, span }) => {
      let billingTeamId: string | null = null;
      let listEntitlements: ReturnType<typeof resolveVmEntitlements> | null = null;
      const requestedBillingTeamId = requestedVmTeamIdFromRequest(request);
      try {
        if (requestedBillingTeamId || user.billingCustomerType === "team") {
          const entitlements = resolveVmEntitlements(user, process.env, {
            requestedBillingTeamId,
            requireTeam: false,
          });
          listEntitlements = entitlements;
          billingTeamId = entitlements.billingTeamId;
          setSpanAttributes(span, {
            "cmux.billing.team_id_set": !!billingTeamId,
            "cmux.billing.customer_type": entitlements.billingCustomerType,
            "cmux.billing.plan_id": entitlements.planId,
          });
        }
      } catch (err) {
        if (isVmBillingTeamResolutionError(err)) {
          return billingTeamErrorResponse(err);
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
        status: entry.status,
        image: entry.image,
        imageVersion: entry.imageVersion,
        createdAt: entry.createdAt,
        displayName: entry.displayName,
      }));
      // Plan context for machine-fleet UIs: how many active VMs this caller may
      // hold and which plan sets that ceiling. Personal accounts skip the team
      // resolution above, so resolve lazily here.
      if (!listEntitlements) {
        try {
          listEntitlements = resolveVmEntitlements(user, process.env, { requireTeam: false });
        } catch {
          listEntitlements = null;
        }
      }
      const limits = listEntitlements
        ? { maxActiveVms: listEntitlements.maxActiveVms, planId: listEntitlements.planId }
        : undefined;
      return jsonResponse({ vms, limits });
    },
  );
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm",
    { "cmux.vm.operation": "create" },
    "/api/vm POST failed",
    async ({ user: initialUser, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "create", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => timing.finish({ status: response.status }));
      let user: AuthedUser = initialUser;
      {
        // Runtime-validate the payload before we call a paid provider. An invalid `provider`
        // (client sending `"aws"` or `"docker"`) previously slipped past the type cast and
        // surfaced as a 500 from the driver after provisioning had already half-succeeded.
        // Allow callers to send no body at all. The handler already falls through to
        // default provider/image, so a bare `curl -X POST /api/vm` should create a default
        // VM. Empty is a default-create; malformed or non-object JSON is rejected below.
        let parsedBody: { readonly bodyWasEmpty: boolean; readonly raw: unknown };
        try {
          parsedBody = await measureVmAsync(timing, "request_parse", async () => {
            const rawText = await request.text();
            const bodyWasEmpty = rawText.length === 0;
            if (bodyWasEmpty) {
              return { bodyWasEmpty, raw: undefined as unknown };
            }
            return { bodyWasEmpty, raw: JSON.parse(rawText) as unknown };
          });
        } catch (err) {
          if (!(err instanceof SyntaxError)) throw err;
          recordSpanError(span, err);
          return vmErrorResponse({
            error: "vm_json_parse_failed",
            status: 400,
            message: "Cloud VM create expected valid JSON.",
            action: "Send `{}` for the default VM, or include only documented fields such as `image` and `teamId`.",
          });
        }
        const { bodyWasEmpty, raw } = parsedBody;
        if (!bodyWasEmpty && (raw === null || typeof raw !== "object" || Array.isArray(raw))) {
          recordSpanError(span, new Error("Cloud VM create body was not a JSON object"));
          return vmErrorResponse({
            error: "vm_expected_object",
            status: 400,
            message: "Cloud VM create expected a JSON object body.",
            action: "Send `{}` for the default VM, or include only documented fields such as `image` and `teamId`.",
          });
        }
        const parsed = parseVmCreateBody((raw ?? {}) as Record<string, unknown>);
        if (!parsed.ok) return parsed.response;
        if (requestHasBlankVmTeamId(request)) {
          return vmInvalidTeamIdResponse();
        }
        const body = parsed.body;
        const provider = body.provider ?? defaultProviderId();
        let imageSelection;
        try {
          assertVmCreateEnabled(provider);
          imageSelection = resolveVmImage(provider, body.image);
        } catch (err) {
          if (isVmCreateDisabledError(err)) {
            return vmErrorResponse({
              error: "vm_create_disabled",
              status: 503,
              message: "Cloud VM creation is disabled for this environment.",
              action: "Ask an admin to enable Cloud VM creation, then retry.",
              reason: "Cloud VM creation is disabled.",
            });
          }
          if (isVmImageConfigError(err)) {
            return vmErrorResponse({
              error: "vm_image_config_error",
              status: 503,
              message: "The requested Cloud VM image is not available in this environment.",
              action: "Retry without `image` to use the default Cloud VM image, or ask an admin to configure a supported image.",
              reason: "Cloud VM image configuration is unavailable.",
              details: { imageRequested: err.image !== undefined },
            });
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
        if (requestedBillingTeamId && !user.teamIds.includes(requestedBillingTeamId)) {
          let refreshedUser: AuthedUser | null;
          try {
            refreshedUser = await measureVmAsync(timing, "auth", () =>
              verifyRequest(request, { requestedTeamId: requestedBillingTeamId })
            );
          } catch (error) {
            return authProviderErrorResponse(error, "/api/vm.create.team-auth");
          }
          if (!refreshedUser) return unauthorized();
          user = refreshedUser;
        }
        // Read-time reconcile: a Stripe subscription change is corrected here
        // right before paid limits apply. Best-effort — billing reads must
        // not block VM creation, so the whole reconcile races a hard
        // deadline and VM create proceeds with current metadata on timeout.
        try {
          if (isStackConfigured()) {
            const changed = await withBillingReconcileDeadline(
              measureVmAsync(timing, "billing_reconcile", async () => {
                const serverUser = await getStackServerApp().getUser(user.id);
                return serverUser ? reconcileProPlanMetadata(serverUser) : false;
              })
            );
            if (changed) {
              const reconciledUser = await measureVmAsync(timing, "auth", () =>
                verifyRequest(request, { requestedTeamId: requestedBillingTeamId })
              );
              if (reconciledUser) user = reconciledUser;
            }
          }
        } catch (err) {
          console.error("[VM] Pro plan reconcile failed", err);
        }
        let entitlements;
        try {
          entitlements = measureVmSync(timing, "entitlements", () =>
            resolveVmEntitlements(user, process.env, {
              requestedBillingTeamId,
              requireTeam: true,
            })
          );
        } catch (err) {
          if (isVmBillingTeamResolutionError(err)) {
            return billingTeamErrorResponse(err);
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

        if (isVmProGateBlocked(entitlements)) {
          return vmRequiresProResponse();
        }

        const maxMemoryMb = maxMemoryMbForPlan(entitlements.planId, process.env);
        const memoryMb =
          body.memoryMb === undefined
            ? defaultMemoryMbForPlan(entitlements.planId, process.env)
            : body.memoryMb;
        if (memoryMb > maxMemoryMb) {
          return vmErrorResponse({
            error: "vm_memory_exceeds_plan",
            status: 400,
            message: "The requested Cloud VM size exceeds this plan's memory limit.",
            action: `Choose a size at or below ${maxMemoryMb} MB, or upgrade the plan before retrying.`,
            details: { requestedMemoryMb: memoryMb, maxMemoryMb, planId: entitlements.planId },
          });
        }
        setSpanAttributes(span, {
          "cmux.vm.memory_mb": memoryMb,
          "cmux.vm.max_memory_mb": maxMemoryMb,
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
            bakedFreestyleSignedAdmin: imageUsesBakedFreestyleSignedAdmin(provider, image),
            persistentHome: body.persistentHome,
            perMachineHome: body.perMachineHome,
            memoryMb,
            timing,
          }));
        } catch (err) {
          const createError = vmCreateWorkflowErrorResponse(err, {
            planId: entitlements.planId,
            limitRetryAction: "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before creating another. Paused VMs do not count against this limit.",
            inProgress: {
              action: "Wait for the first `cmux vm new` to finish. If your terminal was interrupted, retry the same command and cmux will reuse the in-flight request.",
            },
            failed: {
              message: "The previous Cloud VM create attempt failed.",
              action: "Retry with a fresh `cmux vm new`. If it fails again, copy the details and contact support.",
              includeFailureCause: true,
            },
          });
          if (createError) return createError;
          const workflowError = vmWorkflowErrorResponse(err);
          if (workflowError) return workflowError;
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
      }
    },
  );
}

// Upper bound on how long VM creation waits for the best-effort billing
// reconcile (Stripe subscription lookup). On timeout
// the reconcile keeps running in the background (its result is logged, not
// awaited) and VM create proceeds with the user's current plan metadata.
const BILLING_RECONCILE_DEADLINE_MS = 5_000;

export async function withBillingReconcileDeadline(
  reconcile: Promise<boolean>
): Promise<boolean> {
  // Late failures land here instead of surfacing as unhandled rejections.
  const guarded = reconcile.catch((err) => {
    console.error("[VM] Pro plan reconcile failed", err);
    return false;
  });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<false>((resolve) => {
    timer = setTimeout(() => resolve(false), BILLING_RECONCILE_DEADLINE_MS);
  });
  try {
    return await Promise.race([guarded, deadline]);
  } finally {
    clearTimeout(timer);
  }
}

function requestHasBlankVmTeamId(request: Request): boolean {
  for (const header of ["x-cmux-team-id", "x-cmux-billing-team-id"]) {
    const value = request.headers.get(header);
    if (value !== null && value.trim().length === 0) return true;
  }

  let url: URL;
  try {
    url = new URL(request.url);
  } catch {
    return false;
  }

  for (const key of ["teamId", "team_id", "billingTeamId", "billing_team_id"]) {
    for (const value of url.searchParams.getAll(key)) {
      if (value.trim().length === 0) return true;
    }
  }
  return false;
}

function billingTeamErrorResponse(err: {
  readonly code: "vm_billing_team_required" | "vm_billing_team_not_found";
  readonly status: number;
  readonly message: string;
}) {
  if (err.code === "vm_billing_team_not_found") {
    return vmErrorResponse({
      error: err.code,
      status: err.status,
      message: "That team is not available for this account.",
      action: "Switch to a team you belong to, or run `cmux auth login` again and retry with the correct team id.",
      reason: "The selected team is not available for this account.",
    });
  }

  return vmErrorResponse({
    error: err.code,
    status: err.status,
    message: "cmux needs to know which team should own this Cloud VM.",
    action: "Select a team in cmux, or pass the team id with `X-Cmux-Team-Id`. If you do not see a team, run `cmux auth login` again.",
    reason: "No eligible team was selected for this Cloud VM.",
  });
}
