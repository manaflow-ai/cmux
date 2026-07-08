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

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const enterpriseRecipient = "founders@manaflow.com";

const enterpriseContactSchema = z.object({
  firstName: z.string().trim().min(1).max(80),
  lastName: z.string().trim().min(1).max(80),
  companyName: z.string().trim().min(1).max(160),
  jobFunction: z.string().trim().max(120).optional().default(""),
  jobTitle: z.string().trim().min(1).max(120),
  businessEmail: z.string().trim().email().max(320),
  phoneNumber: z.string().trim().min(1).max(80),
  country: z.string().trim().min(1).max(120),
  companySize: z.string().trim().max(80).optional().default(""),
  deploymentNeeds: z.string().trim().max(160).optional().default(""),
  comments: z.string().trim().max(4000).optional().default(""),
  source: z.string().trim().max(80).optional().default("enterprise_page"),
});

type EnterpriseLead = z.infer<typeof enterpriseContactSchema>;

export async function POST(request: Request) {
  return withApiRouteSpan(
    request,
    "/api/enterprise/contact",
    {
      "cmux.subsystem": "enterprise",
      "cmux.enterprise.operation": "contact",
    },
    async (span): Promise<Response> => {
      const config = resolveEnterpriseConfig();
      if (!config) {
        return jsonError("Enterprise contact endpoint is not configured", 503);
      }

      if (process.env.VERCEL === "1") {
        const { error, rateLimited } = await checkRateLimit(
          config.rateLimitId,
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
            "enterprise.contact.rate_limit_not_found",
            config.rateLimitId,
          );
        } else if (error) {
          console.error("enterprise.contact.rate_limit_error", error);
        }
      }

      let payload: unknown;
      try {
        payload = await request.json();
      } catch {
        return jsonError("Invalid JSON payload", 400);
      }

      const parsed = enterpriseContactSchema.safeParse(payload);
      if (!parsed.success) {
        return jsonError("Invalid enterprise contact payload", 400);
      }

      const lead = parsed.data;
      setSpanAttributes(span, {
        "cmux.enterprise.company": lead.companyName,
        "cmux.enterprise.email_domain": emailDomain(lead.businessEmail),
      });

      const deliverable = await checkEmailDeliverable(lead.businessEmail);
      setSpanAttributes(span, {
        "cmux.enterprise.email_check": deliverable,
      });
      if (deliverable === "invalid") {
        return jsonError("Business email cannot receive mail", 400);
      }

      const resend = new Resend(config.resendApiKey);
      const emailResult = await resend.emails.send({
        from: `Manaflow <${config.fromEmail}>`,
        to: [enterpriseRecipient],
        replyTo: lead.businessEmail,
        subject: `Enterprise inquiry: ${lead.companyName}`,
        text: enterpriseLeadText(lead),
        html: enterpriseLeadHtml(lead),
      });
      if (emailResult.error) {
        recordSpanError(span, emailResult.error);
        console.error("enterprise.contact.resend_failed", emailResult.error);
        return jsonError("Failed to email enterprise request", 502);
      }

      // The lead email is already sent — a transient Slack failure must not
      // surface as a form error, or the user resubmits and founders@ gets
      // duplicate leads. Degrade like the PostHog capture below.
      const slackResult = await notifySlack(config.slackWebhookUrl, lead);
      if (!slackResult.ok) {
        recordSpanError(span, slackResult.error);
        console.error("enterprise.contact.slack_failed", slackResult.error);
      }

      const posthogResult = await capturePostHog(lead);
      if (!posthogResult.ok) {
        recordSpanError(span, posthogResult.error);
        console.error("enterprise.contact.posthog_failed", posthogResult.error);
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

function resolveEnterpriseConfig() {
  const resendApiKey = env.RESEND_API_KEY;
  const fromEmail = env.CMUX_FEEDBACK_FROM_EMAIL;
  const rateLimitId = env.CMUX_FEEDBACK_RATE_LIMIT_ID;
  if (!resendApiKey || !fromEmail || !rateLimitId) return null;
  return {
    resendApiKey,
    fromEmail,
    rateLimitId,
    slackWebhookUrl:
      env.SLACK_ENTERPRISE_WEBHOOK_URL
      ?? env.SLACK_WAITLIST_WEBHOOK_URL
      ?? process.env.SLACK_ENTERPRISE_WEBHOOK_URL?.trim()
      ?? process.env.SLACK_WAITLIST_WEBHOOK_URL?.trim(),
  };
}

async function notifySlack(
  webhookUrl: string | undefined,
  lead: EnterpriseLead,
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
        text: slackText(lead),
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
  lead: EnterpriseLead,
): Promise<{ ok: true } | { ok: false; error: Error }> {
  try {
    const response = await fetch(`${POSTHOG_HOST}/capture/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: POSTHOG_PROJECT_KEY,
        event: "cmux_enterprise_contact_submitted",
        distinct_id: lead.businessEmail,
        properties: {
          ...lead,
          emailDomain: emailDomain(lead.businessEmail),
          $set: {
            email: lead.businessEmail,
            company: lead.companyName,
            name: `${lead.firstName} ${lead.lastName}`,
          },
          $set_once: {
            enterprise_contacted_at: new Date().toISOString(),
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

function enterpriseLeadText(lead: EnterpriseLead): string {
  return enterpriseLeadEntries(lead)
    .map(([label, value]) => `${label}: ${value || "-"}`)
    .join("\n");
}

function enterpriseLeadHtml(lead: EnterpriseLead): string {
  const rows = enterpriseLeadEntries(lead)
    .map(
      ([label, value]) =>
        `<tr><th align="left" style="padding:6px 12px 6px 0">${escapeHtml(label)}</th><td style="padding:6px 0">${escapeHtml(value || "-")}</td></tr>`,
    )
    .join("");
  return `<table>${rows}</table>`;
}

function enterpriseLeadEntries(lead: EnterpriseLead): [string, string][] {
  return [
    ["Name", `${lead.firstName} ${lead.lastName}`],
    ["Company", lead.companyName],
    ["Job function", lead.jobFunction],
    ["Job title", lead.jobTitle],
    ["Business email", lead.businessEmail],
    ["Phone number", lead.phoneNumber],
    ["Country", lead.country],
    ["Company size", lead.companySize],
    ["Deployment needs", lead.deploymentNeeds],
    ["Comments", lead.comments],
    ["Source", lead.source],
  ];
}

function slackText(lead: EnterpriseLead): string {
  const lines = [
    ":office: New cmux Enterprise inquiry",
    `*Name:* ${escapeSlack(`${lead.firstName} ${lead.lastName}`)}`,
    `*Company:* ${escapeSlack(lead.companyName)}`,
    `*Email:* ${escapeSlack(lead.businessEmail)}`,
    `*Phone:* ${escapeSlack(lead.phoneNumber)}`,
    `*Country:* ${escapeSlack(lead.country)}`,
  ];
  if (lead.companySize) {
    lines.push(`*Company size:* ${escapeSlack(lead.companySize)}`);
  }
  if (lead.deploymentNeeds) {
    lines.push(`*Deployment:* ${escapeSlack(lead.deploymentNeeds)}`);
  }
  if (lead.comments) {
    lines.push(`*Comments:* ${escapeSlack(lead.comments)}`);
  }
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
