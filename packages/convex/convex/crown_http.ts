import {
  verifyTaskRunToken,
  type TaskRunTokenPayload,
} from "@cmux/shared/task-run-token";
import {
  CrownEvaluationRequestSchema as BaseEvaluationSchema,
  CrownSummarizationRequestSchema as BaseSummarizationSchema,
  WorkerCheckRequestSchema as BaseCheckSchema,
  WorkerTaskRunInfoRequestSchema as BaseTaskRunInfoSchema,
  WorkerAllRunsCompleteRequestSchema as BaseAllRunsCompleteSchema,
  WorkerFinalizeRequestSchema as BaseFinalizeSchema,
  WorkerCompleteRequestSchema as BaseCompleteSchema,
} from "@cmux/shared/crown/schemas";
import { z } from "zod";
import { env } from "../_shared/convex-env";
import { api, internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import type { ActionCtx } from "./_generated/server";
import { httpAction } from "./_generated/server";

const JSON_HEADERS = { "content-type": "application/json" } as const;

// Extend the shared schemas to add Convex ID transformations
const CrownEvaluationRequestSchema = BaseEvaluationSchema.extend({
  taskId: z.string().transform((val) => val as Id<"tasks">),
});

const CrownSummarizationRequestSchema = BaseSummarizationSchema;

const WorkerCheckSchema = BaseCheckSchema.extend({
  taskId: z
    .string()
    .transform((val) => val as Id<"tasks">)
    .optional(),
  taskRunId: z
    .string()
    .transform((val) => val as Id<"taskRuns">)
    .optional(),
});

const WorkerTaskRunInfoSchema = BaseTaskRunInfoSchema.extend({
  taskRunId: z.string().transform((val) => val as Id<"taskRuns">),
});

const WorkerAllRunsCompleteSchema = BaseAllRunsCompleteSchema.extend({
  taskId: z.string().transform((val) => val as Id<"tasks">),
});

const WorkerFinalizeSchema = BaseFinalizeSchema.extend({
  taskId: z.string().transform((val) => val as Id<"tasks">),
  winnerRunId: z.string().transform((val) => val as Id<"taskRuns">),
  candidateRunIds: z
    .array(z.string().transform((val) => val as Id<"taskRuns">))
    .min(1),
});

const WorkerCompleteRequestSchema = BaseCompleteSchema.extend({
  taskRunId: z.string().transform((val) => val as Id<"taskRuns">),
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

type WorkerAuthContext = {
  token: string;
  payload: TaskRunTokenPayload;
};

async function ensureWorkerAuth(req: Request): Promise<WorkerAuthContext> {
  const token = req.headers.get("x-cmux-token");
  if (!token) {
    console.warn("[convex.crown] Missing x-cmux-token header");
    throw new Error("Missing x-cmux-token header");
  }

  try {
    const payload = await verifyTaskRunToken(
      token,
      env.CMUX_TASK_RUN_JWT_SECRET
    );
    return { token, payload };
  } catch (error) {
    console.error("[convex.crown] Failed to verify task run token", error);
    throw new Error("Invalid authentication token");
  }
}

async function loadTaskRunForWorker(
  ctx: ActionCtx,
  auth: WorkerAuthContext,
  runId?: Id<"taskRuns">
): Promise<Doc<"taskRuns">> {
  const taskRunId = runId ?? (auth.payload.taskRunId as Id<"taskRuns">);
  const taskRun = await ctx.runQuery(internal.taskRuns.getById, {
    id: taskRunId,
  });
  if (!taskRun) {
    console.warn("[convex.crown] Task run not found for worker", {
      taskRunId,
    });
    throw new Error("Task run not found");
  }

  if (
    taskRun.teamId !== auth.payload.teamId ||
    taskRun.userId !== auth.payload.userId
  ) {
    console.warn(
      "[convex.crown] Worker attempted to access unauthorized task run",
      {
        taskRunId,
        workerTeamId: auth.payload.teamId,
        taskRunTeamId: taskRun.teamId,
      }
    );
    throw new Error("Unauthorized access to task run");
  }

  return taskRun;
}

export const crownEvaluate = httpAction(async (ctx, req) => {
  let workerAuth: WorkerAuthContext;
  try {
    workerAuth = await ensureWorkerAuth(req);
  } catch (error) {
    console.warn("[convex.crown] Auth failed", error);
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const jsonResult = await ensureJsonRequest(req);
  if (jsonResult instanceof Response) return jsonResult;

  const validation = CrownEvaluationRequestSchema.safeParse(jsonResult.json);
  if (!validation.success) {
    console.warn("[convex.crown] Invalid evaluation payload", validation.error);
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const taskId = validation.data.taskId;

  const teamSlugOrId = workerAuth.payload.teamId;

  let lockAcquired = false;

  try {
    const acquired = await ctx.runMutation(
      internal.tasks.acquireCrownEvaluationLockInternal,
      {
        taskId,
        teamId: workerAuth.payload.teamId,
        userId: workerAuth.payload.userId,
      }
    );

    if (!acquired) {
      return jsonResponse(
        { code: 409, message: "Crown evaluation already in progress" },
        409
      );
    }
    lockAcquired = true;
  } catch (error) {
    console.error("[convex.crown] Failed to acquire evaluation lock", {
      taskId,
      teamSlugOrId,
      error,
    });
    return jsonResponse(
      { code: 500, message: "Failed to acquire evaluation lock" },
      500
    );
  }

  try {
    const result = await ctx.runAction(api.crown.actions.evaluate, {
      taskText: validation.data.taskText,
      candidates: validation.data.candidates,
      teamSlugOrId,
    });
    return jsonResponse(result);
  } catch (error) {
    console.error("[convex.crown] Evaluation error", error);

    if (lockAcquired) {
      try {
        await ctx.runMutation(
          internal.tasks.releaseCrownEvaluationLockInternal,
          {
            taskId,
            teamId: workerAuth.payload.teamId,
            userId: workerAuth.payload.userId,
            crownEvaluationError: "pending_evaluation",
          }
        );
      } catch (resetError) {
        console.error(
          "[convex.crown] Failed to reset crown evaluation state after error",
          {
            taskId,
            teamSlugOrId,
            resetError,
          }
        );
      }
    }

    return jsonResponse({ code: 500, message: "Evaluation failed" }, 500);
  }
});

export const crownSummarize = httpAction(async (ctx, req) => {
  let workerAuth: WorkerAuthContext;
  try {
    workerAuth = await ensureWorkerAuth(req);
  } catch (error) {
    console.warn("[convex.crown] Auth failed", error);
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const jsonResult = await ensureJsonRequest(req);
  if (jsonResult instanceof Response) return jsonResult;

  const validation = CrownSummarizationRequestSchema.safeParse(jsonResult.json);
  if (!validation.success) {
    console.warn(
      "[convex.crown] Invalid summarization payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const teamSlugOrId = workerAuth.payload.teamId;

  try {
    const result = await ctx.runAction(api.crown.actions.summarize, {
      taskText: validation.data.taskText,
      gitDiff: validation.data.gitDiff,
      teamSlugOrId,
    });
    return jsonResponse(result);
  } catch (error) {
    console.error("[convex.crown] Summarization error", error);
    return jsonResponse({ code: 500, message: "Summarization failed" }, 500);
  }
});

export const crownWorkerCheck = httpAction(async (ctx, req) => {
  console.log("[convex.crown] Worker check endpoint called", {
    path: req.url,
    method: req.method,
    hasToken: !!req.headers.get("x-cmux-token"),
  });

  let workerAuth: WorkerAuthContext;
  try {
    workerAuth = await ensureWorkerAuth(req);
  } catch (error) {
    console.warn("[convex.crown] Auth failed", error);
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const jsonResult = await ensureJsonRequest(req);
  if (jsonResult instanceof Response) return jsonResult;

  const validation = WorkerCheckSchema.safeParse(jsonResult.json ?? {});
  if (!validation.success) {
    console.warn(
      "[convex.crown] Invalid worker check payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  console.log("[convex.crown] Worker crown readiness check", {
    taskRunId: validation.data.taskRunId,
    taskId: validation.data.taskId,
  });

  let taskRun: Doc<"taskRuns">;
  try {
    taskRun = await loadTaskRunForWorker(
      ctx,
      workerAuth,
      validation.data.taskRunId
    );
  } catch (error) {
    console.error("[convex.crown] Failed to load task run", error);
    if (error instanceof Error && error.message === "Task run not found") {
      return jsonResponse({ code: 404, message: "Task run not found" }, 404);
    }
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const taskId = validation.data.taskId ?? taskRun.taskId;
  if (taskId !== taskRun.taskId) {
    console.warn("[convex.crown] Worker taskId mismatch", {
      providedTaskId: validation.data.taskId,
      expectedTaskId: taskRun.taskId,
    });
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const task = await ctx.runQuery(internal.tasks.getByIdInternal, {
    id: taskId,
  });
  if (!task) {
    return jsonResponse({ code: 404, message: "Task not found" }, 404);
  }
  if (
    task.teamId !== workerAuth.payload.teamId ||
    task.userId !== workerAuth.payload.userId
  ) {
    console.warn(
      "[convex.crown] Worker attempted to access unauthorized task",
      {
        taskId,
      }
    );
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const workspaceSettings = await ctx.runQuery(
    internal.workspaceSettings.getInternal,
    {
      teamId: workerAuth.payload.teamId,
      userId: workerAuth.payload.userId,
    }
  );

  const runsForTeam = await ctx.runQuery(
    internal.taskRuns.listByTaskForTeamInternal,
    {
      taskId,
      teamId: workerAuth.payload.teamId,
      userId: workerAuth.payload.userId,
    }
  );

  const allRunsFinished = runsForTeam.every((run) =>
    ["completed", "failed"].includes(run.status)
  );
  const allWorkersReported = runsForTeam.every(
    (run) => run.status === "completed"
  );
  const completedRuns = runsForTeam.filter((run) => run.status === "completed");

  const existingEvaluation = await ctx.runQuery(
    internal.crown.getEvaluationByTaskInternal,
    {
      taskId,
      teamId: workerAuth.payload.teamId,
      userId: workerAuth.payload.userId,
    }
  );

  const shouldEvaluate =
    allRunsFinished &&
    allWorkersReported &&
    completedRuns.length >= 2 &&
    !existingEvaluation;

  const singleRunWinnerId =
    runsForTeam.length === 1 && completedRuns.length === 1
      ? completedRuns[0]._id
      : null;

  const runsPayload = runsForTeam.map((run) => ({
    id: run._id,
    status: run.status,
    agentName: run.agentName ?? null,
    newBranch: run.newBranch ?? null,
    exitCode: run.exitCode ?? null,
    completedAt: run.completedAt ?? null,
  }));

  return jsonResponse({
    ok: true,
    taskId,
    allRunsFinished,
    allWorkersReported,
    shouldEvaluate,
    singleRunWinnerId,
    existingEvaluation: existingEvaluation
      ? {
          winnerRunId: existingEvaluation.winnerRunId,
          evaluatedAt: existingEvaluation.evaluatedAt,
        }
      : null,
    task: {
      text: task.text,
      crownEvaluationError: task.crownEvaluationError ?? null,
      isCompleted: task.isCompleted,
      baseBranch: task.baseBranch ?? null,
      projectFullName: task.projectFullName ?? null,
      autoPrEnabled: workspaceSettings?.autoPrEnabled ?? false,
    },
    runs: runsPayload,
  });
});

export const crownWorkerTaskRunInfo = httpAction(async (ctx, req) => {
  let workerAuth: WorkerAuthContext;
  try {
    workerAuth = await ensureWorkerAuth(req);
  } catch (error) {
    console.warn("[convex.crown] Auth failed", error);
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = WorkerTaskRunInfoSchema.safeParse(parsed.json ?? {});
  if (!validation.success) {
    console.warn(
      "[convex.crown] Invalid worker task run info payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const taskRunId = validation.data.taskRunId;

  let taskRun: Doc<"taskRuns">;
  try {
    taskRun = await loadTaskRunForWorker(ctx, workerAuth, taskRunId);
  } catch (error) {
    console.error("[convex.crown] Failed to load task run for info", {
      taskRunId,
      error,
    });
    if (error instanceof Error && error.message === "Task run not found") {
      return jsonResponse({ code: 404, message: "Task run not found" }, 404);
    }
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const task = await ctx.runQuery(internal.tasks.getByIdInternal, {
    id: taskRun.taskId,
  });

  return jsonResponse({
    ok: true,
    taskRun: {
      id: taskRun._id,
      taskId: taskRun.taskId,
      teamId: taskRun.teamId,
      newBranch: taskRun.newBranch ?? null,
      agentName: taskRun.agentName ?? null,
    },
    task: task
      ? {
          id: task._id,
          text: task.text,
          projectFullName: task.projectFullName ?? null,
        }
      : null,
  });
});

export const crownWorkerRunsComplete = httpAction(async (ctx, req) => {
  let workerAuth: WorkerAuthContext;
  try {
    workerAuth = await ensureWorkerAuth(req);
  } catch (error) {
    console.warn("[convex.crown] Auth failed", error);
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const parsed = await ensureJsonRequest(req);
  if (parsed instanceof Response) return parsed;

  const validation = WorkerAllRunsCompleteSchema.safeParse(parsed.json ?? {});
  if (!validation.success) {
    console.warn(
      "[convex.crown] Invalid worker runs complete payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const taskId = validation.data.taskId;

  const task = await ctx.runQuery(internal.tasks.getByIdInternal, {
    id: taskId,
  });
  if (!task) {
    console.error("[convex.crown] Task not found for completion check", {
      taskId,
    });
    return jsonResponse({ code: 404, message: "Task not found" }, 404);
  }
  if (
    task.teamId !== workerAuth.payload.teamId ||
    task.userId !== workerAuth.payload.userId
  ) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const runsForTeam = await ctx.runQuery(
    internal.taskRuns.listByTaskForTeamInternal,
    {
      taskId,
      teamId: workerAuth.payload.teamId,
      userId: workerAuth.payload.userId,
    }
  );

  const statuses = runsForTeam.map((run) => ({
    id: run._id,
    status: run.status,
  }));

  const allComplete =
    runsForTeam.length > 0 &&
    runsForTeam.every((run) => run.status === "completed");

  console.log("[convex.crown] Runs completion check", {
    taskId,
    totalRuns: runsForTeam.length,
    completedRuns: runsForTeam.filter((r) => r.status === "completed").length,
    allComplete,
  });

  return jsonResponse({
    ok: true,
    taskId,
    allComplete,
    statuses,
  });
});

export const crownWorkerFinalize = httpAction(async (ctx, req) => {
  let workerAuth: WorkerAuthContext;
  try {
    workerAuth = await ensureWorkerAuth(req);
  } catch (error) {
    console.warn("[convex.crown] Auth failed", error);
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const jsonResult = await ensureJsonRequest(req);
  if (jsonResult instanceof Response) return jsonResult;

  const validation = WorkerFinalizeSchema.safeParse(jsonResult.json);
  if (!validation.success) {
    console.warn(
      "[convex.crown] Invalid worker finalize payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const taskId = validation.data.taskId;
  const winnerRunId = validation.data.winnerRunId;
  const candidateRunIds = validation.data.candidateRunIds;

  const task = await ctx.runQuery(internal.tasks.getByIdInternal, {
    id: taskId,
  });
  if (!task) {
    return jsonResponse({ code: 404, message: "Task not found" }, 404);
  }
  if (
    task.teamId !== workerAuth.payload.teamId ||
    task.userId !== workerAuth.payload.userId
  ) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const existingEvaluation = await ctx.runQuery(
    internal.crown.getEvaluationByTaskInternal,
    {
      taskId,
      teamId: workerAuth.payload.teamId,
      userId: workerAuth.payload.userId,
    }
  );

  if (existingEvaluation) {
    return jsonResponse({
      ok: true,
      alreadyEvaluated: true,
      winnerRunId: existingEvaluation.winnerRunId,
    });
  }

  try {
    const winningId = await ctx.runMutation(internal.crown.workerFinalize, {
      taskId,
      teamId: workerAuth.payload.teamId,
      userId: workerAuth.payload.userId,
      winnerRunId,
      reason: validation.data.reason,
      summary: validation.data.summary,
      evaluationPrompt: validation.data.evaluationPrompt,
      evaluationResponse: validation.data.evaluationResponse,
      candidateRunIds,
      summarizationPrompt: validation.data.summarizationPrompt,
      summarizationResponse: validation.data.summarizationResponse,
      pullRequest: validation.data.pullRequest,
      pullRequestTitle: validation.data.pullRequestTitle,
      pullRequestDescription: validation.data.pullRequestDescription,
    });

    return jsonResponse({ ok: true, winnerRunId: winningId });
  } catch (error) {
    console.error("[convex.crown] Worker finalize failed", error);
    return jsonResponse({ code: 500, message: "Finalize failed" }, 500);
  }
});

export const crownWorkerComplete = httpAction(async (ctx, req) => {
  console.log("[convex.crown] Worker complete endpoint called", {
    path: req.url,
    method: req.method,
    hasToken: !!req.headers.get("x-cmux-token"),
  });

  let auth: WorkerAuthContext;
  try {
    auth = await ensureWorkerAuth(req);
  } catch (error) {
    console.error("[convex.crown] Auth failed for worker complete", error);
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  const jsonResult = await ensureJsonRequest(req);
  if (jsonResult instanceof Response) return jsonResult;

  const validation = WorkerCompleteRequestSchema.safeParse(jsonResult.json);
  if (!validation.success) {
    console.warn(
      "[convex.crown] Invalid worker complete payload",
      validation.error
    );
    return jsonResponse({ code: 400, message: "Invalid input" }, 400);
  }

  const taskRunId = validation.data.taskRunId;
  console.log("[convex.crown] Loading task run for completion", { taskRunId });

  try {
    await loadTaskRunForWorker(ctx, auth, taskRunId);
  } catch (error) {
    console.error("[convex.crown] Failed to load task run", {
      taskRunId,
      error,
    });
    if (error instanceof Error && error.message === "Task run not found") {
      return jsonResponse({ code: 404, message: "Task run not found" }, 404);
    }
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }

  console.log("[convex.crown] Marking task run as complete", {
    taskRunId,
    exitCode: validation.data.exitCode,
  });

  await ctx.runMutation(internal.taskRuns.workerComplete, {
    taskRunId,
    exitCode: validation.data.exitCode,
  });

  console.log("[convex.crown] Task run marked as complete successfully", {
    taskRunId,
  });

  const updatedRun = await ctx.runQuery(internal.taskRuns.getById, {
    id: taskRunId,
  });

  const task = updatedRun
    ? await ctx.runQuery(internal.tasks.getByIdInternal, {
        id: updatedRun.taskId,
      })
    : null;

  return jsonResponse({
    ok: true,
    taskRun: updatedRun
      ? {
          id: updatedRun._id,
          taskId: updatedRun.taskId,
          teamId: updatedRun.teamId,
          newBranch: updatedRun.newBranch ?? null,
          agentName: updatedRun.agentName ?? null,
        }
      : null,
    task: task
      ? {
          id: task._id,
          text: task.text,
        }
      : null,
  });
});
