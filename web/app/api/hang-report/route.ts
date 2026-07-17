import { checkRateLimit } from "@vercel/firewall";
import { NextResponse } from "next/server";
import { Resend } from "resend";
import { z } from "zod";

import { env } from "@/app/env";
import { recordSpanError, setSpanAttributes, withApiRouteSpan } from "../../../services/telemetry";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const hangReportRecipient = "founders@manaflow.ai";
// Keep multipart requests below Vercel Functions' 4.5 MB request-body limit.
const maxArchiveBytes = Math.floor(3.5 * 1024 * 1024);
const gzipMagic = Buffer.from([0x1f, 0x8b]);

const hangReportSchema = z.object({
  summary: z.string().trim().min(1).max(8000),
  email: z
    .union([z.literal(""), z.string().trim().email().max(320)])
    .optional()
    .default(""),
  gistUrl: z
    .union([
      z.literal(""),
      z
        .string()
        .trim()
        .max(500)
        .url()
        .refine(
          (value) => value.startsWith("https://gist.github.com/"),
          "gistUrl must be a gist.github.com URL",
        ),
    ])
    .optional()
    .default(""),
  appVersion: z.string().trim().max(120).optional().default(""),
  osVersion: z.string().trim().max(200).optional().default(""),
});

type PreparedArchive = {
  content: Buffer;
  filename: string;
  size: number;
};

export async function POST(request: Request) {
  return withApiRouteSpan(
    request,
    "/api/hang-report",
    { "cmux.subsystem": "hang-report", "cmux.hang_report.operation": "send" },
    async (span): Promise<Response> => {
      const config = resolveHangReportConfig();
      if (!config) {
        return jsonError("Hang report endpoint is not configured", 503);
      }

      if (process.env.VERCEL === "1") {
        const { error, rateLimited } = await checkRateLimit(
          config.rateLimitId,
          { request },
        );

        setSpanAttributes(span, { "cmux.rate_limited": rateLimited || error === "blocked" });
        if (rateLimited || error === "blocked") {
          return jsonError("Rate limit exceeded", 429);
        }

        if (error === "not-found") {
          console.error("hang_report.route.rate_limit_not_found", config.rateLimitId);
          return jsonError("service_unavailable", 503);
        } else if (error) {
          console.error("hang_report.route.rate_limit_error", error);
          return jsonError("service_unavailable", 503);
        }
      }

      let formData: FormData;
      try {
        formData = await request.formData();
      } catch {
        return jsonError("Invalid multipart payload", 400);
      }

      const parsed = hangReportSchema.safeParse({
        summary: getString(formData, "summary"),
        email: getString(formData, "email"),
        gistUrl: getString(formData, "gistUrl"),
        appVersion: getString(formData, "appVersion"),
        osVersion: getString(formData, "osVersion"),
      });

      if (!parsed.success) {
        return jsonError("Invalid hang report payload", 400);
      }

      const archiveResult = await prepareArchive(formData.get("archive"));
      if ("errorResponse" in archiveResult) {
        return archiveResult.errorResponse;
      }
      const archive = archiveResult.archive;

      const { appVersion, email, gistUrl, osVersion, summary } = parsed.data;
      if (!archive && !gistUrl) {
        return jsonError("A hang report needs an archive or a gistUrl", 400);
      }

      setSpanAttributes(span, {
        "cmux.hang_report.summary_length": summary.length,
        "cmux.hang_report.archive_bytes": archive?.size ?? 0,
        "cmux.hang_report.gist_url_set": gistUrl.length > 0,
      });

      const resend = new Resend(config.resendApiKey);
      const { error } = await resend.emails.send({
        from: `Manaflow <${config.fromEmail}>`,
        to: [hangReportRecipient],
        ...(email ? { replyTo: email } : {}),
        subject: buildSubject(summary, appVersion),
        text: buildTextBody({ appVersion, archive, email, gistUrl, osVersion, summary }),
        ...(archive
          ? {
              attachments: [
                {
                  content: archive.content,
                  contentType: "application/gzip",
                  filename: archive.filename,
                },
              ],
            }
          : {}),
      });

      if (error) {
        recordSpanError(span, error);
        console.error("hang_report.route.resend_failed", error);
        return jsonError("Failed to send hang report", 502);
      }

      return NextResponse.json(
        { ok: true },
        {
          headers: {
            "Cache-Control": "no-store",
          },
        },
      );
    },
  );
}

function resolveHangReportConfig() {
  const resendApiKey = env.RESEND_API_KEY;
  const fromEmail = env.CMUX_FEEDBACK_FROM_EMAIL;
  const rateLimitId = env.CMUX_HANG_REPORT_RATE_LIMIT_ID ?? env.CMUX_FEEDBACK_RATE_LIMIT_ID;

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

type PrepareArchiveResult =
  | { archive: PreparedArchive | null }
  | { errorResponse: Response };

async function prepareArchive(value: FormDataEntryValue | null): Promise<PrepareArchiveResult> {
  if (!(value instanceof File) || value.name.length === 0) {
    return { archive: null };
  }

  if (value.size > maxArchiveBytes) {
    return { errorResponse: jsonError("Archive is too large (max 3.5 MB)", 413) };
  }

  const content = Buffer.from(await value.arrayBuffer());
  // Validate the payload is actually gzip data rather than trusting the
  // client-supplied content type.
  if (content.length < 2 || !content.subarray(0, 2).equals(gzipMagic)) {
    return { errorResponse: jsonError("Archive must be a .tar.gz file", 415) };
  }

  return {
    archive: {
      content,
      filename: sanitizeFilename(value.name),
      size: value.size,
    },
  };
}

function buildSubject(summary: string, appVersion: string) {
  const firstNonEmptyLine =
    summary
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find(Boolean) ?? "Hang report";
  const headline =
    firstNonEmptyLine.length > 72
      ? `${firstNonEmptyLine.slice(0, 69)}...`
      : firstNonEmptyLine;
  const stamp = appVersion ? ` [v${appVersion}]` : "";

  return `cmux hang report${stamp}: ${headline}`;
}

function buildTextBody(input: {
  appVersion: string;
  archive: PreparedArchive | null;
  email: string;
  gistUrl: string;
  osVersion: string;
  summary: string;
}) {
  return [
    `From: ${input.email || "not provided"}`,
    `App version: ${input.appVersion || "unknown"}`,
    `macOS: ${input.osVersion || "unknown"}`,
    `Gist: ${input.gistUrl || "none"}`,
    input.archive
      ? `Archive: ${input.archive.filename} (${input.archive.size} bytes, attached)`
      : "Archive: none",
    "",
    "Summary:",
    input.summary,
  ].join("\n");
}

function sanitizeFilename(fileName: string) {
  const cleaned = fileName.replace(/[\r\n"]/g, "").trim();
  return cleaned.length > 0 ? cleaned : "cmux-hang-report.tar.gz";
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
