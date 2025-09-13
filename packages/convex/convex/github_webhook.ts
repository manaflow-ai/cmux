import type {
  InstallationEvent,
  PullRequestEvent,
  WebhookEvent,
} from "@octokit/webhooks-types";
import { env } from "../_shared/convex-env";
import { bytesToHex } from "../_shared/encoding";
import { hmacSha256, safeEqualHex, sha256Hex } from "../_shared/crypto";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";

async function verifySignature(
  secret: string,
  payload: string,
  signatureHeader: string | null
): Promise<boolean> {
  if (!signatureHeader || !signatureHeader.startsWith("sha256=")) return false;
  const expectedHex = signatureHeader.slice("sha256=".length).toLowerCase();
  const sigBuf = await hmacSha256(secret, payload);
  const computedHex = bytesToHex(sigBuf).toLowerCase();
  return safeEqualHex(computedHex, expectedHex);
}

export const githubWebhook = httpAction(async (_ctx, req) => {
  if (!env.GITHUB_APP_WEBHOOK_SECRET) {
    return new Response("webhook not configured", { status: 501 });
  }
  const payload = await req.text();
  const event = req.headers.get("x-github-event");
  const delivery = req.headers.get("x-github-delivery");
  const signature = req.headers.get("x-hub-signature-256");

  if (
    !(await verifySignature(env.GITHUB_APP_WEBHOOK_SECRET, payload, signature))
  ) {
    return new Response("invalid signature", { status: 400 });
  }

  let body: WebhookEvent;
  try {
    body = JSON.parse(payload) as WebhookEvent;
  } catch {
    return new Response("invalid payload", { status: 400 });
  }

  type WithInstallation = { installation?: { id?: number } };
  const installationId: number | undefined = (body as WithInstallation).installation?.id;

  // Record delivery for idempotency/auditing
  if (delivery) {
    const payloadHash = await sha256Hex(payload);
    await _ctx.runMutation(internal.github_app.recordWebhookDelivery, {
      provider: "github",
      deliveryId: delivery,
      installationId,
      payloadHash,
    });
  }

  // Handle ping quickly
  if (event === "ping") {
    return new Response("pong", { status: 200 });
  }

  try {
    switch (event) {
      case "installation": {
        const inst = body as InstallationEvent;
        const action = inst?.action as string | undefined;
        if (!action) break;
        if (action === "created") {
          const account = inst?.installation?.account;
          if (account && installationId !== undefined) {
            await _ctx.runMutation(
              internal.github_app.upsertProviderConnectionFromInstallation,
              {
                installationId,
                accountLogin: String(account.login ?? ""),
                accountId: Number(account.id ?? 0),
                accountType:
                  account.type === "Organization" ? "Organization" : "User",
              }
            );
          }
        } else if (action === "deleted") {
          if (installationId !== undefined) {
            await _ctx.runMutation(
              internal.github_app.deactivateProviderConnection,
              {
                installationId,
              }
            );
          }
        }
        break;
      }
      case "installation_repositories":
      case "repository":
      case "create":
      case "delete":
      case "push":
      case "pull_request":
      case "pull_request_review":
      case "pull_request_review_comment":
      case "issue_comment":
      case "check_suite":
      case "check_run":
      case "status":
      case "workflow_run":
      case "workflow_job": {
        if (event === "pull_request") {
          try {
            const prPayload = body as PullRequestEvent;
            const repoFullName = String(prPayload.repository?.full_name ?? "");
            const installation = Number(prPayload.installation?.id ?? 0);
            if (!repoFullName || !installation) break;
            const conn = await _ctx.runQuery(
              internal.github_app.getProviderConnectionByInstallationId,
              { installationId: installation }
            );
            const teamId = conn?.teamId;
            if (!teamId) break;
            await _ctx.runMutation(internal.github_prs.upsertFromWebhookPayload, {
              installationId: installation,
              repoFullName,
              teamId,
              payload: prPayload,
            });
          } catch (_err) {
            // swallow
          }
        }
        break;
      }
      default: {
        // Accept unknown events to avoid retries.
        break;
      }
    }
  } catch (_err) {
    // Swallow errors to avoid GitHub retries while we iterate
  }

  return new Response("ok", { status: 200 });
});
