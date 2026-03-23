import { checkRateLimit } from "@vercel/firewall";
import { NextResponse } from "next/server";
import { Resend } from "resend";
import { z } from "zod";

import { env } from "@/app/env";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const feedbackRecipient = "feedback@manaflow.com";
const maxAttachmentCount = 10;
const maxAttachmentBytes = 4 * 1024 * 1024;
// Keep multipart requests below Vercel Functions' 4.5 MB request-body limit.
const maxTotalAttachmentBytes = 4 * 1024 * 1024;
const allowedImageTypes = new Set([
  "image/gif",
  "image/heic",
  "image/heif",
  "image/jpeg",
  "image/png",
  "image/tiff",
  "image/webp",
]);

const feedbackSchema = z.object({
  email: z.string().trim().email().max(320),
  message: z.string().trim().min(1).max(4000),
  appVersion: z.string().trim().max(120).optional().default(""),
  appBuild: z.string().trim().max(120).optional().default(""),
  appCommit: z.string().trim().max(120).optional().default(""),
  bundleIdentifier: z.string().trim().max(200).optional().default(""),
  osVersion: z.string().trim().max(200).optional().default(""),
  locale: z.string().trim().max(120).optional().default(""),
  hardwareModel: z.string().trim().max(120).optional().default(""),
  chip: z.string().trim().max(200).optional().default(""),
  memoryGB: z.string().trim().max(20).optional().default(""),
  architecture: z.string().trim().max(20).optional().default(""),
  displayInfo: z.string().trim().max(200).optional().default(""),
});

type PreparedAttachment = {
  content: Buffer;
  contentType: string;
  filename: string;
  size: number;
};

export async function POST(request: Request) {
  const feedbackConfig = resolveFeedbackConfig();
  if (!feedbackConfig) {
    return jsonError("Feedback endpoint is not configured", 503);
  }

  if (process.env.VERCEL === "1") {
    const { error, rateLimited } = await checkRateLimit(
      feedbackConfig.rateLimitId,
      { request },
    );

    if (rateLimited || error === "blocked") {
      return jsonError("Rate limit exceeded", 429);
    }

    if (error === "not-found") {
      console.error(
        "feedback.route.rate_limit_not_found",
        feedbackConfig.rateLimitId,
      );
    } else if (error) {
      console.error("feedback.route.rate_limit_error", error);
    }
  }

  let formData: FormData;
  try {
    formData = await request.formData();
  } catch {
    return jsonError("Invalid multipart payload", 400);
  }

  const parsed = feedbackSchema.safeParse({
    email: getString(formData, "email"),
    message: getString(formData, "message"),
    appVersion: getString(formData, "appVersion"),
    appBuild: getString(formData, "appBuild"),
    appCommit: getString(formData, "appCommit"),
    bundleIdentifier: getString(formData, "bundleIdentifier"),
    osVersion: getString(formData, "osVersion"),
    locale: getString(formData, "locale"),
    hardwareModel: getString(formData, "hardwareModel"),
    chip: getString(formData, "chip"),
    memoryGB: getString(formData, "memoryGB"),
    architecture: getString(formData, "architecture"),
    displayInfo: getString(formData, "displayInfo"),
  });

  if (!parsed.success) {
    return jsonError("Invalid feedback payload", 400);
  }

  const attachmentsResult = await prepareAttachments(
    formData.getAll("attachments"),
  );
  if ("errorResponse" in attachmentsResult) {
    return attachmentsResult.errorResponse;
  }

  const {
    appBuild, appCommit, appVersion, architecture, bundleIdentifier, chip,
    displayInfo, email, hardwareModel, locale, memoryGB, message, osVersion,
  } = parsed.data;
  const subject = buildSubject(email, message, appVersion);
  const attachments = attachmentsResult.attachments;
  const resend = new Resend(feedbackConfig.resendApiKey);

  const { error } = await resend.emails.send({
    from: `Manaflow <${feedbackConfig.fromEmail}>`,
    to: [feedbackRecipient],
    replyTo: email,
    subject,
    text: buildTextBody({
      email,
      message,
      appVersion,
      appBuild,
      appCommit,
      bundleIdentifier,
      osVersion,
      locale,
      hardwareModel,
      chip,
      memoryGB,
      architecture,
      displayInfo,
      attachments,
    }),
    html: buildHtmlBody({
      email,
      message,
      appVersion,
      appBuild,
      appCommit,
      bundleIdentifier,
      osVersion,
      locale,
      hardwareModel,
      chip,
      memoryGB,
      architecture,
      displayInfo,
      attachments,
    }),
    attachments: attachments.map((attachment) => ({
      content: attachment.content,
      contentType: attachment.contentType,
      filename: attachment.filename,
    })),
  });

  if (error) {
    console.error("feedback.route.resend_failed", error);
    return jsonError("Failed to send feedback", 502);
  }

  return NextResponse.json(
    { ok: true },
    {
      headers: {
        "Cache-Control": "no-store",
      },
    },
  );
}

function resolveFeedbackConfig() {
  const resendApiKey = env.RESEND_API_KEY;
  const fromEmail = env.CMUX_FEEDBACK_FROM_EMAIL;
  const rateLimitId = env.CMUX_FEEDBACK_RATE_LIMIT_ID;

  if (!resendApiKey || !fromEmail || !rateLimitId) {
    return null;
  }

  return {
    resendApiKey,
    fromEmail,
    rateLimitId,
  };
}

function getString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

async function prepareAttachments(values: FormDataEntryValue[]) {
  const files = values.filter(
    (value): value is File => value instanceof File && value.name.length > 0,
  );

  if (files.length > maxAttachmentCount) {
    return {
      errorResponse: jsonError("Too many images attached", 400),
    };
  }

  let totalSize = 0;
  const attachments: PreparedAttachment[] = [];

  for (const file of files) {
    if (!allowedImageTypes.has(file.type)) {
      return {
        errorResponse: jsonError("Unsupported image attachment type", 415),
      };
    }

    if (file.size > maxAttachmentBytes) {
      return {
        errorResponse: jsonError("Image attachment is too large", 413),
      };
    }

    totalSize += file.size;
    if (totalSize > maxTotalAttachmentBytes) {
      return {
        errorResponse: jsonError("Total image attachment size is too large", 413),
      };
    }

    attachments.push({
      content: Buffer.from(await file.arrayBuffer()),
      contentType: file.type,
      filename: sanitizeFilename(file.name),
      size: file.size,
    });
  }

  return { attachments };
}

function buildSubject(email: string, message: string, appVersion: string) {
  const firstNonEmptyLine =
    message
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find(Boolean) ?? "Feedback";
  const summary =
    firstNonEmptyLine.length > 72
      ? `${firstNonEmptyLine.slice(0, 69)}...`
      : firstNonEmptyLine;
  const versionSuffix = appVersion ? ` (v${appVersion})` : "";

  return `cmux feedback from ${email}${versionSuffix}: ${summary}`;
}

function buildTextBody(input: {
  email: string;
  message: string;
  appVersion: string;
  appBuild: string;
  appCommit: string;
  bundleIdentifier: string;
  osVersion: string;
  locale: string;
  hardwareModel: string;
  chip: string;
  memoryGB: string;
  architecture: string;
  displayInfo: string;
  attachments: PreparedAttachment[];
}) {
  const attachmentLines =
    input.attachments.length === 0
      ? "Attachments: none"
      : [
          "Attachments:",
          ...input.attachments.map(
            (attachment) =>
              `- ${attachment.filename} (${attachment.contentType}, ${attachment.size} bytes)`,
          ),
        ].join("\n");

  return [
    `From: ${input.email}`,
    `App version: ${input.appVersion || "unknown"}`,
    `App build: ${input.appBuild || "unknown"}`,
    `App commit: ${input.appCommit || "unknown"}`,
    `Bundle identifier: ${input.bundleIdentifier || "unknown"}`,
    `macOS: ${input.osVersion || "unknown"}`,
    `Locale: ${input.locale || "unknown"}`,
    `Hardware model: ${input.hardwareModel || "unknown"}`,
    `Chip: ${input.chip || "unknown"}`,
    `Memory: ${input.memoryGB || "unknown"}`,
    `Architecture: ${input.architecture || "unknown"}`,
    `Displays: ${input.displayInfo || "unknown"}`,
    attachmentLines,
    "",
    "Message:",
    input.message,
  ].join("\n");
}

function buildHtmlBody(input: {
  email: string;
  message: string;
  appVersion: string;
  appBuild: string;
  appCommit: string;
  bundleIdentifier: string;
  osVersion: string;
  locale: string;
  hardwareModel: string;
  chip: string;
  memoryGB: string;
  architecture: string;
  displayInfo: string;
  attachments: PreparedAttachment[];
}) {
  const attachmentMarkup =
    input.attachments.length === 0
      ? "<p><strong>Attachments:</strong> none</p>"
      : `<p><strong>Attachments:</strong></p><ul>${input.attachments
          .map(
            (attachment) =>
              `<li>${escapeHtml(attachment.filename)} (${escapeHtml(
                attachment.contentType,
              )}, ${attachment.size} bytes)</li>`,
          )
          .join("")}</ul>`;

  return `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#111827;line-height:1.5">
      <h1 style="font-size:18px;margin:0 0 16px">cmux feedback</h1>
      <p><strong>From:</strong> ${escapeHtml(input.email)}</p>
      <p><strong>App version:</strong> ${escapeHtml(input.appVersion || "unknown")}</p>
      <p><strong>App build:</strong> ${escapeHtml(input.appBuild || "unknown")}</p>
      <p><strong>App commit:</strong> ${escapeHtml(input.appCommit || "unknown")}</p>
      <p><strong>Bundle identifier:</strong> ${escapeHtml(
        input.bundleIdentifier || "unknown",
      )}</p>
      <p><strong>macOS:</strong> ${escapeHtml(input.osVersion || "unknown")}</p>
      <p><strong>Locale:</strong> ${escapeHtml(input.locale || "unknown")}</p>
      <p><strong>Hardware model:</strong> ${escapeHtml(input.hardwareModel || "unknown")}</p>
      <p><strong>Chip:</strong> ${escapeHtml(input.chip || "unknown")}</p>
      <p><strong>Memory:</strong> ${escapeHtml(input.memoryGB || "unknown")}</p>
      <p><strong>Architecture:</strong> ${escapeHtml(input.architecture || "unknown")}</p>
      <p><strong>Displays:</strong> ${escapeHtml(input.displayInfo || "unknown")}</p>
      ${attachmentMarkup}
      <h2 style="font-size:15px;margin:24px 0 8px">Message</h2>
      <pre style="white-space:pre-wrap;font:13px/1.6 SFMono-Regular,Menlo,monospace;background:#f3f4f6;border-radius:10px;padding:12px">${escapeHtml(
        input.message,
      )}</pre>
    </div>
  `.trim();
}

function sanitizeFilename(fileName: string) {
  const cleaned = fileName.replace(/[\r\n"]/g, "").trim();
  return cleaned.length > 0 ? cleaned : "attachment";
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function jsonError(message: string, status: number) {
  return NextResponse.json(
    { error: message },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
      },
    },
  );
}
