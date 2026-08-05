// Devbox REST surface: one persistent Daytona VM per user with a persistent volume.
// GET reports the caller's devbox (or null), POST is get-or-create, DELETE destroys
// the VM and releases the claim while keeping the volume for the next create.

import { assertDevboxEnabled, assertVmCreateEnabled } from "../../../services/vms/config";
import {
  ensureDevbox,
  getDevbox,
  isDevboxNotFoundError,
  releaseDevbox,
  runDevboxWorkflow,
  DEVBOX_PROVIDER,
} from "../../../services/vms/devbox";
import { isVmProGateBlocked } from "../../../services/vms/entitlements";
import {
  isVmCreateCreditsInsufficientError,
  isVmCreateDisabledError,
  isVmCreateFailedError,
  isVmCreateInProgressError,
  isVmImageConfigError,
  isVmLimitExceededError,
} from "../../../services/vms/errors";
import { resolveVmImage } from "../../../services/vms/images/resolver";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  vmRequiresProResponse,
  withAuthedVmApiRoute,
} from "../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../services/telemetry";
import { devboxNotFoundResponse } from "./shared";

export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/devbox",
    { "cmux.vm.operation": "devbox_get" },
    "/api/devbox GET failed",
    async ({ user }) => {
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      const devbox = await runDevboxWorkflow(getDevbox({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
      }));
      return jsonResponse({ devbox });
    },
  );
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/devbox",
    { "cmux.vm.operation": "devbox_ensure" },
    "/api/devbox POST failed",
    async ({ user, span }) => {
      const account = resolveVmRouteAccountScope(user, request, { requireTeam: true });
      if (!account.ok) return account.response;
      if (isVmProGateBlocked(account.entitlements)) {
        return vmRequiresProResponse();
      }

      let imageSelection;
      try {
        assertDevboxEnabled();
        assertVmCreateEnabled(DEVBOX_PROVIDER);
        imageSelection = resolveVmImage(DEVBOX_PROVIDER, undefined);
      } catch (err) {
        if (isVmCreateDisabledError(err)) {
          return vmErrorResponse({
            error: "devbox_create_disabled",
            status: 503,
            message: "Devbox creation is disabled for this environment.",
            action: "Ask an admin to enable devbox creation, then retry.",
            reason: err.reason,
          });
        }
        if (isVmImageConfigError(err)) {
          return vmErrorResponse({
            error: "devbox_image_config_error",
            status: 503,
            message: "The devbox image is not configured in this environment.",
            action: "Ask an admin to configure DAYTONA_SANDBOX_SNAPSHOT.",
            reason: "Devbox image configuration is unavailable.",
          });
        }
        throw err;
      }

      const rawKey = (
        request.headers.get("idempotency-key") ||
        request.headers.get("x-cmux-idempotency-key") ||
        ""
      ).trim();
      const idempotencyKey = rawKey ? rawKey.slice(0, 128) : undefined;
      setSpanAttributes(span, {
        "cmux.vm.provider": DEVBOX_PROVIDER,
        "cmux.vm.image_version": imageSelection.imageVersion,
        "cmux.idempotency_key_set": !!idempotencyKey,
      });

      try {
        const result = await runDevboxWorkflow(ensureDevbox({
          userId: user.id,
          billingCustomerType: account.entitlements.billingCustomerType,
          billingTeamId: account.entitlements.billingTeamId,
          billingPlanId: account.entitlements.planId,
          maxActiveVms: account.entitlements.maxActiveVms,
          teamIds: user.teamIds,
          image: imageSelection.image,
          imageVersion: imageSelection.imageVersion,
          idempotencyKey,
        }));
        setSpanAttributes(span, { "cmux.devbox.created": result.created });
        return jsonResponse({ devbox: result.devbox, created: result.created }, result.created ? 201 : 200);
      } catch (err) {
        if (isVmCreateInProgressError(err)) {
          return vmErrorResponse({
            error: "devbox_create_in_progress",
            status: 409,
            message: "A devbox create is already running for this account.",
            action: "Wait for the first create to finish, then retry the same request.",
          });
        }
        if (isVmCreateFailedError(err)) {
          return vmErrorResponse({
            error: "devbox_create_failed",
            status: 500,
            message: "The previous devbox create attempt failed.",
            action: "Retry. If it fails again, copy the details and contact support.",
            details: { failureCode: err.code, failureMessage: err.message },
          });
        }
        if (isVmLimitExceededError(err)) {
          return vmErrorResponse({
            error: "vm_limit_exceeded",
            status: 429,
            message: "This team already has the maximum number of active Cloud VMs.",
            action: "Pause or destroy another Cloud VM, then retry.",
            details: { limit: err.limit },
          });
        }
        if (isVmCreateCreditsInsufficientError(err)) {
          return vmErrorResponse({
            error: "vm_create_credits_insufficient",
            status: 402,
            message: "This account has no Cloud VM create credits left.",
            action: "Upgrade the plan or contact support for more credits.",
          });
        }
        throw err;
      }
    },
  );
}

export async function DELETE(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/devbox",
    { "cmux.vm.operation": "devbox_release" },
    "/api/devbox DELETE failed",
    async ({ user }) => {
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      try {
        const result = await runDevboxWorkflow(releaseDevbox({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
        }));
        return jsonResponse({ released: result.released, volumeName: result.volumeName });
      } catch (err) {
        if (isDevboxNotFoundError(err)) return devboxNotFoundResponse();
        throw err;
      }
    },
  );
}
