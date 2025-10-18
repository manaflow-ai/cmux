import {
  codeReviewCallbackSchema,
  codeReviewFileCallbackSchema,
  type CodeReviewCallbackPayload,
  type CodeReviewFileCallbackPayload,
} from "@cmux/shared/codeReview/callback-schemas";
import { api } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { httpAction } from "./_generated/server";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: JSON_HEADERS,
  });
}

function getBearerToken(req: Request): string | null {
  const header = req.headers.get("authorization");
  if (!header) {
    const headers: Record<string, string> = {};
    req.headers.forEach((value, key) => {
      headers[key] = value;
    });
    console.warn("[code-review.callback] Authorization header missing", {
      headers,
    });
    return null;
  }
  const trimmed = header.trim();
  const lower = trimmed.toLowerCase();
  const prefix = "bearer ";
  if (!lower.startsWith(prefix)) {
    console.warn("[code-review.callback] Authorization header not bearer", {
      authorization: header,
    });
    return null;
  }
  const token = trimmed.slice(prefix.length).trim();
  if (token.length === 0) {
    console.warn("[code-review.callback] Authorization bearer token empty", {
      authorization: header,
    });
    return null;
  }
  return token;
}

async function parseJsonRequest(req: Request): Promise<unknown | Response> {
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return jsonResponse(
      {
        code: 415,
        message: "Content-Type must be application/json",
      },
      415,
    );
  }
  try {
    return await req.json();
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON body" }, 400);
  }
}

export const codeReviewJobCallback = httpAction(async (ctx, req) => {
  const token = getBearerToken(req);
  if (!token) {
    console.warn("[code-review.callback] Missing bearer token");
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await parseJsonRequest(req);
  if (parsed instanceof Response) {
    return parsed;
  }

  let payload: CodeReviewCallbackPayload;
  try {
    payload = codeReviewCallbackSchema.parse(parsed);
  } catch (error) {
    console.error("[code-review.callback] Invalid payload", error);
    return jsonResponse({ code: 400, message: "Invalid payload" }, 400);
  }

  try {
    if (payload.status === "success") {
      console.info("[code-review.callback] Received success payload", {
        jobId: payload.jobId,
        sandboxInstanceId: payload.sandboxInstanceId,
        tokenPreview: token.slice(0, 8),
      });
      await ctx.runMutation(api.codeReview.completeJobFromCallback, {
        jobId: payload.jobId as Id<"automatedCodeReviewJobs">,
        callbackToken: token,
        sandboxInstanceId: payload.sandboxInstanceId,
        codeReviewOutput: payload.codeReviewOutput,
      });
    } else {
      console.info("[code-review.callback] Received failure payload", {
        jobId: payload.jobId,
        sandboxInstanceId: payload.sandboxInstanceId,
        errorCode: payload.errorCode,
        tokenPreview: token.slice(0, 8),
      });
      await ctx.runMutation(api.codeReview.failJobFromCallback, {
        jobId: payload.jobId as Id<"automatedCodeReviewJobs">,
        callbackToken: token,
        sandboxInstanceId: payload.sandboxInstanceId,
        errorCode: payload.errorCode,
        errorDetail: payload.errorDetail,
      });
    }
    return jsonResponse({ ok: true }, 200);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "Unknown error");
    console.error("[code-review.callback] Failed to process callback", message);
    return jsonResponse({ code: 500, message }, 500);
  }
});

export const codeReviewFileCallback = httpAction(async (ctx, req) => {
  const token = getBearerToken(req);
  if (!token) {
    console.warn("[code-review.file-callback] Missing bearer token");
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await parseJsonRequest(req);
  if (parsed instanceof Response) {
    return parsed;
  }

  let payload: CodeReviewFileCallbackPayload;
  try {
    payload = codeReviewFileCallbackSchema.parse(parsed);
  } catch (error) {
    console.error("[code-review.file-callback] Invalid payload", error);
    return jsonResponse({ code: 400, message: "Invalid payload" }, 400);
  }

  try {
    console.info("[code-review.file-callback] Upserting file output", {
      jobId: payload.jobId,
      filePath: payload.filePath,
      tokenPreview: token.slice(0, 8),
    });
    await ctx.runMutation(api.codeReview.upsertFileOutputFromCallback, {
      jobId: payload.jobId as Id<"automatedCodeReviewJobs">,
      callbackToken: token,
      filePath: payload.filePath,
      codexReviewOutput: payload.codexReviewOutput,
      sandboxInstanceId: payload.sandboxInstanceId,
      commitRef: payload.commitRef,
    });
    return jsonResponse({ ok: true }, 200);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "Unknown error");
    console.error(
      "[code-review.file-callback] Failed to process callback",
      message,
    );
    return jsonResponse({ code: 500, message }, 500);
  }
});
