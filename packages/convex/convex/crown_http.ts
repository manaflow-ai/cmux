import { z } from "zod";
import { api } from "./_generated/api";
import { httpAction } from "./_generated/server";
import type { ActionCtx } from "./_generated/server";

const JSON_HEADERS = { "content-type": "application/json" } as const;

const CrownEvaluationRequestSchema = z.object({
  prompt: z.string(),
  teamSlugOrId: z.string(),
});

const CrownSummarizationRequestSchema = z.object({
  prompt: z.string(),
  teamSlugOrId: z.string().optional(),
});

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

async function ensureJsonRequest(
  req: Request
): Promise<{ json: unknown } | Response> {
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return jsonResponse(
      { code: 415, message: "Content-Type must be application/json" },
      415
    );
  }

  try {
    const json = await req.json();
    return { json };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON body" }, 400);
  }
}

function ensureStackAuth(req: Request): Response | void {
  const stackAuthHeader = req.headers.get("x-stack-auth");
  if (!stackAuthHeader) {
    console.error("[convex.crown] Missing x-stack-auth header");
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  try {
    const parsed = JSON.parse(stackAuthHeader) as { accessToken?: string };
    if (!parsed.accessToken) {
      console.error("[convex.crown] Missing access token in x-stack-auth header");
      return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
    }
  } catch (error) {
    console.error("[convex.crown] Failed to parse x-stack-auth header", error);
    return jsonResponse({ code: 400, message: "Invalid stack auth header" }, 400);
  }
}

async function ensureTeamMembership(
  ctx: ActionCtx,
  teamSlugOrId: string
): Promise<Response | { teamId: string }> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    console.warn("[convex.crown] Anonymous request rejected");
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const team = await ctx.runQuery(api.teams.get, { teamSlugOrId });
  if (!team) {
    console.warn("[convex.crown] Team not found", { teamSlugOrId });
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const memberships = await ctx.runQuery(api.teams.listTeamMemberships, {});
  const hasMembership = memberships.some((membership) => {
    return membership.teamId === team.uuid;
  });

  if (!hasMembership) {
    console.warn("[convex.crown] User missing membership", {
      teamSlugOrId,
      userId: identity.subject,
    });
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  return { teamId: team.uuid };
}

async function resolveTeamSlugOrId(
  ctx: ActionCtx,
  teamSlugOrId?: string
): Promise<Response | { teamSlugOrId: string }> {
  if (teamSlugOrId) {
    const membership = await ensureTeamMembership(ctx, teamSlugOrId);
    if (membership instanceof Response) {
      return membership;
    }
    return { teamSlugOrId };
  }

  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    console.warn("[convex.crown] Anonymous request rejected");
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const memberships = await ctx.runQuery(api.teams.listTeamMemberships, {});
  if (memberships.length === 0) {
    console.warn("[convex.crown] User has no team memberships", {
      userId: identity.subject,
    });
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const primary = memberships[0];
  const slugOrId = primary.team?.slug ?? primary.teamId;
  if (!slugOrId) {
    console.error("[convex.crown] Unable to resolve default team", {
      membership: primary,
    });
    return jsonResponse({ code: 500, message: "Team resolution failed" }, 500);
  }

  return { teamSlugOrId: slugOrId };
}

export const crownEvaluate = httpAction(async (ctx, req) => {
  const stackAuthError = ensureStackAuth(req);
  if (stackAuthError) return stackAuthError;

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = CrownEvaluationRequestSchema.safeParse(parsed.json);
  if (!validation.success) {
    console.warn("[convex.crown] Invalid evaluation payload", validation.error);
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const membership = await ensureTeamMembership(
    ctx,
    validation.data.teamSlugOrId
  );
  if (membership instanceof Response) return membership;

  try {
    const result = await ctx.runAction(api.crown.actions.evaluate, {
      prompt: validation.data.prompt,
      teamSlugOrId: validation.data.teamSlugOrId,
    });
    return jsonResponse(result);
  } catch (error) {
    console.error("[convex.crown] Evaluation error", error);
    return jsonResponse({ code: 500, message: "Evaluation failed" }, 500);
  }
});

export const crownSummarize = httpAction(async (ctx, req) => {
  const stackAuthError = ensureStackAuth(req);
  if (stackAuthError) return stackAuthError;

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = CrownSummarizationRequestSchema.safeParse(parsed.json);
  if (!validation.success) {
    console.warn("[convex.crown] Invalid summarization payload", validation.error);
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const resolvedTeam = await resolveTeamSlugOrId(
    ctx,
    validation.data.teamSlugOrId
  );
  if (resolvedTeam instanceof Response) return resolvedTeam;

  try {
    const result = await ctx.runAction(api.crown.actions.summarize, {
      prompt: validation.data.prompt,
      teamSlugOrId: resolvedTeam.teamSlugOrId,
    });
    return jsonResponse(result);
  } catch (error) {
    console.error("[convex.crown] Summarization error", error);
    return jsonResponse({ code: 500, message: "Summarization failed" }, 500);
  }
});

