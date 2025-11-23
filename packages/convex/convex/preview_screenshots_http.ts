import {
  PreviewScreenshotUploadPayloadSchema,
  ScreenshotUploadUrlRequestSchema,
} from "@cmux/shared/convex-safe";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { httpAction } from "./_generated/server";
import { getWorkerAuth } from "./users/utils/getWorkerAuth";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

async function ensureJsonRequest(
  req: Request,
): Promise<{ json: unknown } | Response> {
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return jsonResponse(
      { code: 415, message: "Content-Type must be application/json" },
      415,
    );
  }

  try {
    const json = await req.json();
    return { json };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON body" }, 400);
  }
}

export const uploadPreviewScreenshot = httpAction(async (ctx, req) => {
  const auth = await getWorkerAuth(req, {
    loggerPrefix: "[preview-screenshots]",
  });
  if (!auth) {
    throw jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = PreviewScreenshotUploadPayloadSchema.safeParse(
    parsed.json,
  );
  if (!validation.success) {
    console.warn(
      "[preview-screenshots] Invalid screenshot upload payload",
      validation.error,
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const payload = validation.data;

  // Verify preview run exists
  const data = await ctx.runQuery(internal.previewRuns.getRunWithConfig, {
    previewRunId: payload.previewRunId,
  });

  if (!data?.run) {
    return jsonResponse({ code: 404, message: "Preview run not found" }, 404);
  }

  const { run } = data;

  // Verify auth matches team
  if (run.teamId !== auth.payload.teamId) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const storedScreens = (payload.images ?? []).map((image) => ({
    storageId: image.storageId as Id<"_storage">,
    mimeType: image.mimeType,
    fileName: image.fileName,
    commitSha: image.commitSha,
    width: image.width,
    height: image.height,
  }));

  if (payload.status === "completed") {
    if (!payload.images || payload.images.length === 0) {
      return jsonResponse(
        { code: 400, message: "At least one screenshot image is required" },
        400,
      );
    }
  }

  const screenshotSetId = await ctx.runMutation(
    internal.previewScreenshots.createScreenshotSet,
    {
      previewRunId: payload.previewRunId,
      status: payload.status,
      commitSha: payload.commitSha,
      error: payload.error,
      images: storedScreens,
    },
  );

  // Trigger GitHub comment posting
  if (screenshotSetId) {
    await ctx.scheduler.runAfter(
      0,
      internal.previewScreenshots.triggerGithubComment,
      {
        previewRunId: payload.previewRunId,
      },
    );
  }

  return jsonResponse({
    ok: true,
    storageIds: storedScreens.map((shot) => shot.storageId),
    screenshotSetId,
  });
});

export const createPreviewScreenshotUploadUrl = httpAction(
  async (ctx, req) => {
    const auth = await getWorkerAuth(req, {
      loggerPrefix: "[preview-screenshots]",
    });
    if (!auth) {
      throw jsonResponse({ code: 401, message: "Unauthorized" }, 401);
    }

    const parsed = await ensureJsonRequest(req);
    if (parsed instanceof Response) return parsed;

    const validation = ScreenshotUploadUrlRequestSchema.safeParse(parsed.json);
    if (!validation.success) {
      console.warn(
        "[preview-screenshots] Invalid upload URL request payload",
        validation.error,
      );
      return jsonResponse({ code: 400, message: "Invalid input" }, 400);
    }

    const uploadUrl = await ctx.storage.generateUploadUrl();
    return jsonResponse({ ok: true, uploadUrl });
  },
);
