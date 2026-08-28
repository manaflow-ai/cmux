import { checkRateLimit } from "@vercel/firewall";
import { NextResponse } from "next/server";
import { Resend } from "resend";
import { z } from "zod";

import { env } from "@/app/env";
import {
  POSTHOG_HOST,
  POSTHOG_PROJECT_KEY,
} from "../../../../services/analytics/iosEventPolicy";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "../../../../services/telemetry";
import { checkEmailDeliverable } from "../../waitlist/email-check";


const supportRecipient = "founders@manaflow.com";

const supportRequestSchema = z.object({
  name: z.string().trim().max(160).optional().default(""),
  email: z.string().trim().email().max(320),
  topic: z.string().trim().max(120).optional().default(""),
  message: z.string().trim().min(1).max(4000),
  source: z.string().trim().max(80).optional().default("support_page"),
});

type SupportRequest = z.infer<typeof supportRequestSchema>;

export async function POST(request: Request) {
  return withApiRouteSpan(
    request,
    "/api/support/contact",
    {
      "cmux.subsystem": "support",
      "cmux.support.operation": "contact",
    },
    async (span): Promise<Response> => {
      const config = resolveSupportConfig();
      if (!config) {
        return jsonError("Support contact endpoint is not configured", 503);
      }

      if (process.env.VERCEL === "1" && config.rateLimitId) {
        let result: Awaited<ReturnType<typeof checkRateLimit>>;
        try {
          result = await checkRateLimit(config.rateLimitId, { request });
        } catch {
          // A firewall transport failure must not fall through to Resend. The
          // endpoint is an expensive, externally visible side effect.
          console.error("support.contact.rate_limit_error", {
            failure: "check_failed",
          });
          return jsonError("service_unavailable", 503);
        }
        const { error, rateLimited } = result;
        setSpanAttributes(span, {
          "cmux.rate_limited": rateLimited || error === "blocked",
        });
        if (rateLimited || error === "blocked") {
          return jsonError("Rate limit exceeded", 429);
        }
        if (error === "not-found") {
          console.error(
            "support.contact.rate_limit_not_found",
            config.rateLimitId,
          );
        } else if (error) {
          console.error("support.contact.rate_limit_error", {
            failure: "check_error",
          });
          return jsonError("service_unavailable", 503);
        }
      }

      let payload: unknown;
      try {
        payload = await request.json();
      } catch {
        return jsonError("Invalid JSON payload", 400);
      }

      const parsed = supportRequestSchema.safeParse(payload);
      if (!parsed.success) {
        return jsonError("Invalid support request payload", 400);
      }

      const ticket = parsed.data;
      setSpanAttributes(span, {
        "cmux.support.topic": ticket.topic,
        "cmux.support.email_domain": emailDomain(ticket.email),
      });

      const deliverable = await checkEmailDeliverable(ticket.email);
      setSpanAttributes(span, {
        "cmux.support.email_check": deliverable,
      });
      if (deliverable === "invalid") {
        return jsonError("Email address cannot receive mail", 400);
      }

      const resend = new Resend(config.resendApiKey);
      const emailResult = await resend.emails.send({
        from: `Manaflow <${config.fromEmail}>`,
        to: [supportRecipient],
        replyTo: ticket.email,
        subject: ticket.topic
          ? `Support request (${ticket.topic}): ${ticket.email}`
          : `Support request: ${ticket.email}`,
        text: supportRequestText(ticket),
        html: supportRequestHtml(ticket),
      });
      if (emailResult.error) {
        recordSpanError(span, emailResult.error);
        console.error("support.contact.resend_failed", emailResult.error);
        return jsonError("Failed to email support request", 502);
      }

      // The support email is already sent — a transient Slack failure must not
      // surface as a form error, or the user resubmits and founders@ gets
      // duplicate requests. Degrade like the PostHog capture below.
      const slackResult = await notifySlack(config.slackWebhookUrl, ticket);
      if (!slackResult.ok) {
        recordSpanError(span, slackResult.error);
        console.error("support.contact.slack_failed", slackResult.error);
      }

      const posthogResult = await capturePostHog(ticket);
      if (!posthogResult.ok) {
        recordSpanError(span, posthogResult.error);
        console.error("support.contact.posthog_failed", posthogResult.error);
      }

      return NextResponse.json(
        {
          ok: true,
          email: "sent",
          slack: !slackResult.ok
            ? "failed"
            : slackResult.skipped
              ? "skipped"
              : "sent",
          posthog: posthogResult.ok ? "sent" : "failed",
        },
        { headers: { "Cache-Control": "no-store" } },
      );
    },
  );
}

function resolveSupportConfig() {
  const resendApiKey = env.RESEND_API_KEY;
  const fromEmail = env.CMUX_FEEDBACK_FROM_EMAIL;
  // rateLimitId is optional: unset means the route runs without rate limiting.
  const rateLimitId = env.CMUX_FEEDBACK_RATE_LIMIT_ID;
  if (!resendApiKey || !fromEmail) return null;
  return {
    resendApiKey,
    fromEmail,
    rateLimitId,
    slackWebhookUrl:
      env.SLACK_SUPPORT_WEBHOOK_URL
      ?? env.SLACK_ENTERPRISE_WEBHOOK_URL
      ?? env.SLACK_WAITLIST_WEBHOOK_URL,
  };
}

async function notifySlack(
  webhookUrl: string | undefined,
  ticket: SupportRequest,
): Promise<
  | { ok: true; skipped: boolean }
  | { ok: false; error: Error }
> {
  if (!webhookUrl) return { ok: true, skipped: true };

  try {
    const response = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text: slackText(ticket),
      }),
    });
    if (!response.ok) {
      return {
        ok: false,
        error: new Error(`slack webhook ${response.status}`),
      };
    }
    return { ok: true, skipped: false };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error : new Error(String(error)),
    };
  }
}

async function capturePostHog(
  ticket: SupportRequest,
): Promise<{ ok: true } | { ok: false; error: Error }> {
  try {
    const response = await fetch(`${POSTHOG_HOST}/capture/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: POSTHOG_PROJECT_KEY,
        event: "cmux_support_request_submitted",
        distinct_id: ticket.email,
        properties: {
          ...ticket,
          emailDomain: emailDomain(ticket.email),
          $set: {
            email: ticket.email,
            ...(ticket.name ? { name: ticket.name } : {}),
          },
          $set_once: {
            support_contacted_at: new Date().toISOString(),
          },
        },
        timestamp: new Date().toISOString(),
      }),
    });
    if (!response.ok) {
      return {
        ok: false,
        error: new Error(`posthog capture ${response.status}`),
      };
    }
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error : new Error(String(error)),
    };
  }
}

function supportRequestText(ticket: SupportRequest): string {
  return supportRequestEntries(ticket)
    .map(([label, value]) => `${label}: ${value || "-"}`)
    .join("\n");
}

function supportRequestHtml(ticket: SupportRequest): string {
  const rows = supportRequestEntries(ticket)
    .map(
      ([label, value]) =>
        `<tr><th align="left" style="padding:6px 12px 6px 0">${escapeHtml(label)}</th><td style="padding:6px 0">${escapeHtml(value || "-")}</td></tr>`,
    )
    .join("");
  return `<table>${rows}</table>`;
}

function supportRequestEntries(ticket: SupportRequest): [string, string][] {
  return [
    ["Name", ticket.name],
    ["Email", ticket.email],
    ["Topic", ticket.topic],
    ["Message", ticket.message],
    ["Source", ticket.source],
  ];
}

function slackText(ticket: SupportRequest): string {
  const lines = [
    ":sos: New cmux support request",
    `*Email:* ${escapeSlack(ticket.email)}`,
  ];
  if (ticket.name) {
    lines.push(`*Name:* ${escapeSlack(ticket.name)}`);
  }
  if (ticket.topic) {
    lines.push(`*Topic:* ${escapeSlack(ticket.topic)}`);
  }
  lines.push(`*Message:* ${escapeSlack(ticket.message)}`);
  return lines.join("\n");
}

function emailDomain(email: string): string {
  return email.slice(email.lastIndexOf("@") + 1).toLowerCase();
}

function escapeSlack(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function jsonError(message: string, status: number) {
  return NextResponse.json(
    { error: message },
    { status, headers: { "Cache-Control": "no-store" } },
  );
}
