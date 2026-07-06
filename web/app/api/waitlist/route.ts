import { checkRateLimit } from "@vercel/firewall";
import { NextResponse } from "next/server";
import { z } from "zod";

import { env } from "@/app/env";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "../../../services/telemetry";
import { checkEmailDeliverable } from "./email-check";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const WAITLIST_PLATFORMS = ["linux", "android", "windows"] as const;

const PLATFORM_LABELS: Record<(typeof WAITLIST_PLATFORMS)[number], string> = {
  linux: "Linux",
  android: "Android",
  windows: "Windows",
};

const waitlistSchema = z.object({
  email: z.string().trim().email().max(320),
  platforms: z
    .array(z.enum(WAITLIST_PLATFORMS))
    .min(1)
    .max(WAITLIST_PLATFORMS.length),
  location: z.string().trim().max(64).optional().default(""),
  // The client calls this route twice: first to validate the email before
  // recording the signup (`notify: false`), then to fan out the Slack ping
  // after the durable PostHog capture succeeds (`notify: true`). Defaults to
  // `true` so a caller that omits the flag (e.g. a stale page bundle loaded
  // before this change) keeps the original notify-on-valid behavior.
  notify: z.boolean().optional().default(true),
});

/**
 * Gates and announces waitlist signups. It (1) checks that the email's domain
 * can plausibly receive mail (MX/disposable check) so bogus addresses never get
 * recorded, and (2) when `notify` is set, pings Slack. The durable signup record
 * itself lives in PostHog (captured client-side), so a Slack failure never
 * invalidates the signup — but an undeliverable email is rejected before the
 * client records it.
 */
export async function POST(request: Request) {
  return withApiRouteSpan(
    request,
    "/api/waitlist",
    { "cmux.subsystem": "waitlist", "cmux.waitlist.operation": "notify" },
    async (span): Promise<Response> => {
      // Rate-limit the whole public endpoint up front, before the DNS lookups
      // below. The validate phase resolves a user-supplied domain (MX + A/AAAA),
      // and unique domains miss the cache, so an unthrottled path would let a
      // public POST flood the resolver as well as Slack. Reuses the feedback
      // rule. Only active on Vercel.
      if (process.env.VERCEL === "1") {
        const { error, rateLimited } = await checkRateLimit(
          env.CMUX_FEEDBACK_RATE_LIMIT_ID,
          { request },
        );
        setSpanAttributes(span, {
          "cmux.rate_limited": rateLimited || error === "blocked",
        });
        if (rateLimited || error === "blocked") {
          return jsonError("Rate limit exceeded", 429);
        }
        if (error === "not-found") {
          console.error(
            "waitlist.route.rate_limit_not_found",
            env.CMUX_FEEDBACK_RATE_LIMIT_ID,
          );
          return jsonError("Rate limiter unavailable", 503);
        } else if (error) {
          console.error("waitlist.route.rate_limit_error", error);
          return jsonError("Rate limiter unavailable", 503);
        }
      }

      let payload: unknown;
      try {
        payload = await request.json();
      } catch {
        return jsonError("Invalid JSON payload", 400);
      }

      const parsed = waitlistSchema.safeParse(payload);
      if (!parsed.success) {
        return jsonError("Invalid waitlist payload", 400);
      }
      const { email, platforms, location, notify } = parsed.data;
      setSpanAttributes(span, {
        "cmux.waitlist.platform_count": platforms.length,
        "cmux.waitlist.location": location,
      });

      // Reject addresses whose domain can't receive mail (typos, fake domains,
      // disposable inboxes) before the client records the signup. Transient DNS
      // failures resolve to "unknown" and fail open so a resolver hiccup never
      // blocks a real signup.
      const deliverable = await checkEmailDeliverable(email);
      setSpanAttributes(span, { "cmux.waitlist.email_check": deliverable });
      if (deliverable === "invalid") {
        return ok({ valid: false });
      }

      // Email looks deliverable. The validate-only first phase stops here; only
      // the post-record `notify` call fans out to Slack.
      if (!notify) {
        return ok({ valid: true, slack: "skipped" });
      }

      const webhookUrl = env.SLACK_WAITLIST_WEBHOOK_URL;
      if (!webhookUrl) {
        // Not configured: accept so the client signup flow still succeeds.
        return ok({ valid: true, slack: "skipped" });
      }

      try {
        // Platform labels come from a fixed enum; email + location are
        // user-controlled, so escape Slack mrkdwn metacharacters (`&`, `<`, `>`)
        // to keep `<!channel>`, `<@USER>`, and link syntax from rendering or
        // notifying the channel.
        const platformList = platforms
          .map((p) => PLATFORM_LABELS[p])
          .join(", ");
        const fromSuffix = location
          ? ` (from ${escapeSlack(location)})`
          : "";
        const res = await fetch(webhookUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            text: `:tada: New waitlist signup: *${escapeSlack(email)}* for *${platformList}*${fromSuffix}`,
          }),
        });
        if (!res.ok) {
          recordSpanError(span, new Error(`slack webhook ${res.status}`));
          return jsonError("Failed to notify Slack", 502);
        }
      } catch (error) {
        recordSpanError(span, error);
        return jsonError("Failed to notify Slack", 502);
      }

      return ok({ valid: true, slack: "sent" });
    },
  );
}

// Escape the characters Slack treats specially in mrkdwn so user-controlled
// text can't inject links, mentions, or channel broadcasts.
function escapeSlack(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function ok(extra: Record<string, unknown>) {
  return NextResponse.json(
    { ok: true, ...extra },
    { headers: { "Cache-Control": "no-store" } },
  );
}

function jsonError(message: string, status: number) {
  return NextResponse.json(
    { error: message },
    { status, headers: { "Cache-Control": "no-store" } },
  );
}
