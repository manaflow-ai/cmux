import type { InstallationEvent, WebhookEvent } from "@octokit/webhooks-types";
import { env } from "../_shared/convex-env";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";

function safeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let res = 0;
  for (let i = 0; i < a.length; i++) {
    res |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return res === 0;
}

async function verifySignature(
  secret: string,
  payload: string,
  signatureHeader: string | null
): Promise<boolean> {
  if (!signatureHeader || !signatureHeader.startsWith("sha256=")) return false;
  const expectedHex = signatureHeader.slice("sha256=".length).toLowerCase();
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigBuf = await crypto.subtle.sign("HMAC", key, enc.encode(payload));
  const computedHex = Array.from(new Uint8Array(sigBuf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .toLowerCase();
  return safeEqualHex(computedHex, expectedHex);
}

async function sha256Hex(input: string): Promise<string> {
  const enc = new TextEncoder();
  const digest = await crypto.subtle.digest("SHA-256", enc.encode(input));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
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
        // Future: additional mutations to persist repo/branch/PR/CI state.
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
