import type {
  CheckRunEvent,
  DeploymentEvent,
  DeploymentStatusEvent,
  InstallationEvent,
  InstallationRepositoriesEvent,
  PullRequestEvent,
  PushEvent,
  StatusEvent,
  WebhookEvent,
  WorkflowRunEvent,
} from "@octokit/webhooks-types";
import { env } from "../_shared/convex-env";
import { hmacSha256, safeEqualHex, sha256Hex } from "../_shared/crypto";
import { bytesToHex } from "../_shared/encoding";
import { streamInstallationRepositories } from "../_shared/githubApp";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";

const DEBUG_FLAGS = {
  githubWebhook: false, // set true to emit verbose push diagnostics
};

const FEATURE_FLAGS = {
  githubEyesReactionOnPrOpen: true,
};

async function verifySignature(
  secret: string,
  payload: string,
  signatureHeader: string | null,
): Promise<boolean> {
  if (!signatureHeader || !signatureHeader.startsWith("sha256=")) return false;
  const expectedHex = signatureHeader.slice("sha256=".length).toLowerCase();
  const sigBuf = await hmacSha256(secret, payload);
  const computedHex = bytesToHex(sigBuf).toLowerCase();
  return safeEqualHex(computedHex, expectedHex);
}

const MILLIS_THRESHOLD = 1_000_000_000_000;

function normalizeTimestamp(
  value: number | string | null | undefined,
): number | undefined {
  if (value === null || value === undefined) return undefined;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return undefined;
    const normalized = value > MILLIS_THRESHOLD ? value : value * 1000;
    return Math.round(normalized);
  }
  const numeric = Number(value);
  if (Number.isFinite(numeric)) {
    const normalized = numeric > MILLIS_THRESHOLD ? numeric : numeric * 1000;
    return Math.round(normalized);
  }
  const parsed = Date.parse(value);
  if (!Number.isNaN(parsed)) {
    return parsed;
  }
  return undefined;
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
  const installationId: number | undefined = (body as WithInstallation)
    .installation?.id;

  // Record delivery for idempotency/auditing
  if (delivery) {
    const payloadHash = await sha256Hex(payload);
    const result = await _ctx.runMutation(internal.github_app.recordWebhookDelivery, {
      provider: "github",
      deliveryId: delivery,
      installationId,
      payloadHash,
    });
    if (!result.created) {
      return new Response("ok (duplicate)", { status: 200 });
    }
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
              },
            );
          }
        } else if (action === "deleted") {
          if (installationId !== undefined) {
            await _ctx.runMutation(
              internal.github_app.deactivateProviderConnection,
              {
                installationId,
              },
            );
          }
        }
        break;
      }
      case "installation_repositories": {
        try {
          const inst = body as InstallationRepositoriesEvent;
          const installation = Number(inst.installation?.id ?? installationId ?? 0);
          if (!installation) {
            break;
          }

          const connection = await _ctx.runQuery(
            internal.github_app.getProviderConnectionByInstallationId,
            { installationId: installation },
          );
          if (!connection) {
            console.warn(
              "[github_webhook] No provider connection found for installation during repo sync",
              {
                installation,
                delivery,
              },
            );
            break;
          }

          const teamId = connection.teamId;
          const userId = connection.connectedByUserId;
          if (!teamId || !userId) {
            console.warn(
              "[github_webhook] Missing team/user context for installation repo sync",
              {
                installation,
                teamId,
                userId,
                delivery,
              },
            );
            break;
          }

          await streamInstallationRepositories(
            installation,
            (repos, currentPageIndex) =>
              (async () => {
                try {
                  await _ctx.runMutation(internal.github.syncReposForInstallation, {
                    teamId,
                    userId,
                    connectionId: connection._id,
                    repos,
                  });
                } catch (error) {
                  console.error(
                    "[github_webhook] Failed to sync installation repositories from webhook",
                    {
                      installation,
                      delivery,
                      pageIndex: currentPageIndex,
                      repoCount: repos.length,
                      error,
                    },
                  );
                }
              })(),
          );
        } catch (error) {
          console.error(
            "[github_webhook] Unexpected error handling installation_repositories webhook",
            {
              error,
              delivery,
            },
          );
        }
        break;
      }
      case "repository":
      case "create":
      case "delete":
      case "pull_request_review":
      case "pull_request_review_comment":
      case "issue_comment": {
        break;
      }
      case "workflow_run": {
        try {
          const workflowRunPayload = body as WorkflowRunEvent;
          const repoFullName = String(
            workflowRunPayload.repository?.full_name ?? "",
          );
          const installation = Number(workflowRunPayload.installation?.id ?? 0);


          if (!repoFullName || !installation) {
            console.warn("[workflow_run] Missing repoFullName or installation", {
              repoFullName,
              installation,
              delivery,
            });
            break;
          }

          const conn = await _ctx.runQuery(
            internal.github_app.getProviderConnectionByInstallationId,
            { installationId: installation },
          );
          const teamId = conn?.teamId;

          if (!teamId) {
            console.warn("[workflow_run] No teamId found for installation", {
              installation,
              delivery,
              connectionFound: !!conn,
            });
            break;
          }


          await _ctx.runMutation(
            internal.github_workflows.upsertWorkflowRunFromWebhook,
            {
              installationId: installation,
              repoFullName,
              teamId,
              payload: workflowRunPayload,
            },
          );

        } catch (err) {
          console.error("[workflow_run] Handler failed", {
            err,
            delivery,
            message: err instanceof Error ? err.message : String(err),
            stack: err instanceof Error ? err.stack : undefined,
          });
        }
        break;
      }
      case "workflow_job": {
        // For now, just acknowledge workflow_job events without processing
        // In the future, we could track individual job details if needed
        break;
      }
      case "check_run": {
        try {
          const checkRunPayload = body as CheckRunEvent;
          const repoFullName = String(checkRunPayload.repository?.full_name ?? "");
          const installation = Number(checkRunPayload.installation?.id ?? 0);


          if (!repoFullName || !installation) {
            console.warn("[check_run] Missing repoFullName or installation", {
              repoFullName,
              installation,
              delivery,
            });
            break;
          }

          const conn = await _ctx.runQuery(
            internal.github_app.getProviderConnectionByInstallationId,
            { installationId: installation },
          );
          const teamId = conn?.teamId;

          if (!teamId) {
            console.warn("[check_run] No teamId found for installation", {
              installation,
              delivery,
              connectionFound: !!conn,
            });
            break;
          }


          await _ctx.runMutation(internal.github_check_runs.upsertCheckRunFromWebhook, {
            installationId: installation,
            repoFullName,
            teamId,
            payload: checkRunPayload,
          });

        } catch (err) {
          console.error("[check_run] Handler failed", {
            err,
            delivery,
            message: err instanceof Error ? err.message : String(err),
            stack: err instanceof Error ? err.stack : undefined,
          });
        }
        break;
      }
      case "check_suite": {
        break;
      }
      case "deployment": {
        try {
          const deploymentPayload = body as DeploymentEvent;
          const repoFullName = String(deploymentPayload.repository?.full_name ?? "");
          const installation = Number(deploymentPayload.installation?.id ?? 0);


          if (!repoFullName || !installation) {
            console.warn("[deployment] Missing repoFullName or installation", {
              repoFullName,
              installation,
              delivery,
            });
            break;
          }

          const conn = await _ctx.runQuery(
            internal.github_app.getProviderConnectionByInstallationId,
            { installationId: installation },
          );
          const teamId = conn?.teamId;

          if (!teamId) {
            console.warn("[deployment] No teamId found for installation", {
              installation,
              delivery,
              connectionFound: !!conn,
            });
            break;
          }

          await _ctx.runMutation(
            internal.github_deployments.upsertDeploymentFromWebhook,
            {
              installationId: installation,
              repoFullName,
              teamId,
              payload: deploymentPayload,
            },
          );

        } catch (err) {
          console.error("[deployment] Handler failed", {
            err,
            delivery,
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }
      case "deployment_status": {
        try {
          const deploymentStatusPayload = body as DeploymentStatusEvent;
          const repoFullName = String(deploymentStatusPayload.repository?.full_name ?? "");
          const installation = Number(deploymentStatusPayload.installation?.id ?? 0);


          if (!repoFullName || !installation) {
            console.warn("[deployment_status] Missing repoFullName or installation", {
              repoFullName,
              installation,
              delivery,
            });
            break;
          }

          const conn = await _ctx.runQuery(
            internal.github_app.getProviderConnectionByInstallationId,
            { installationId: installation },
          );
          const teamId = conn?.teamId;

          if (!teamId) {
            console.warn("[deployment_status] No teamId found for installation", {
              installation,
              delivery,
              connectionFound: !!conn,
            });
            break;
          }

          await _ctx.runMutation(
            internal.github_deployments.updateDeploymentStatusFromWebhook,
            {
              installationId: installation,
              repoFullName,
              teamId,
              payload: deploymentStatusPayload,
            },
          );

        } catch (err) {
          console.error("[deployment_status] Handler failed", {
            err,
            delivery,
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }
      case "status": {
        try {
          const statusPayload = body as StatusEvent;
          const repoFullName = String(statusPayload.repository?.full_name ?? "");
          const installation = Number(statusPayload.installation?.id ?? 0);


          if (!repoFullName || !installation) {
            console.warn("[status] Missing repoFullName or installation", {
              repoFullName,
              installation,
              delivery,
            });
            break;
          }

          const conn = await _ctx.runQuery(
            internal.github_app.getProviderConnectionByInstallationId,
            { installationId: installation },
          );
          const teamId = conn?.teamId;

          if (!teamId) {
            console.warn("[status] No teamId found for installation", {
              installation,
              delivery,
              connectionFound: !!conn,
            });
            break;
          }

          await _ctx.runMutation(
            internal.github_commit_statuses.upsertCommitStatusFromWebhook,
            {
              installationId: installation,
              repoFullName,
              teamId,
              payload: statusPayload,
            },
          );

        } catch (err) {
          console.error("[status] Handler failed", {
            err,
            delivery,
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }
      case "pull_request": {
        try {
          const prPayload = body as PullRequestEvent;
          const repoFullName = String(prPayload.repository?.full_name ?? "");
          const installation = Number(prPayload.installation?.id ?? 0);
          if (!repoFullName || !installation) break;
          const conn = await _ctx.runQuery(
            internal.github_app.getProviderConnectionByInstallationId,
            { installationId: installation },
          );
          const teamId = conn?.teamId;
          if (!teamId) break;

          // Run both mutations in parallel for better performance
          // These are independent operations that don't depend on each other
          await Promise.all([
            // Update PR record in database
            _ctx.runMutation(internal.github_prs.upsertFromWebhookPayload, {
              installationId: installation,
              repoFullName,
              teamId,
              payload: prPayload,
            }),
            // Handle PR merge/close events to update taskRuns and tasks
            _ctx.runMutation(internal.github_pr_merge_handler.processPullRequestWebhook, {
              teamId,
              payload: prPayload,
            }),
          ]);

          // Add eyes emoji reaction when a new PR is opened
          // Extract pull_request before action narrowing to avoid TypeScript never type issue
          // (PullRequestOpenedEvent intersection reduces to never due to closed_at type conflict)
          const pullRequest = prPayload.pull_request;
          if (
            FEATURE_FLAGS.githubEyesReactionOnPrOpen &&
            prPayload.action === "opened"
          ) {
            const prNumber = Number(pullRequest?.number ?? 0);
            if (prNumber) {
              await _ctx.runAction(internal.github_pr_comments.addPrReaction, {
                installationId: installation,
                repoFullName,
                prNumber,
                content: "eyes",
              });
            }
          }

          const action = prPayload.action ?? "";
          if (
            ["opened", "reopened", "synchronize", "ready_for_review"].includes(
              action,
            )
          ) {
            const previewConfig = await _ctx.runQuery(
              internal.previewConfigs.getByInstallationAndRepo,
              { installationId: installation, repoFullName },
            );

            if (previewConfig) {
              const prNumber = Number(prPayload.pull_request?.number ?? 0);
              const prUrl = prPayload.pull_request?.html_url ?? null;
              const prTitle = prPayload.pull_request?.title ?? undefined;
              const prDescription = prPayload.pull_request?.body ?? undefined;
              const headSha = prPayload.pull_request?.head?.sha ?? null;
              const baseSha = prPayload.pull_request?.base?.sha ?? undefined;
              const headRef = prPayload.pull_request?.head?.ref ?? undefined;
              const headRepoFullName = prPayload.pull_request?.head?.repo?.full_name ?? undefined;
              const headRepoCloneUrl = prPayload.pull_request?.head?.repo?.clone_url ?? undefined;

              console.log("[preview-jobs] Preview config found for PR", {
                repoFullName,
                prNumber,
                prUrl,
                headSha: headSha?.slice(0, 7),
                headRef,
                headRepoFullName,
                isFromFork: headRepoFullName && headRepoFullName !== repoFullName,
                previewConfigId: previewConfig._id,
              });

              if (prNumber && prUrl && headSha) {
                try {
                  // Use previewConfig.teamId instead of connection's teamId
                  // The previewConfig was set up with a specific team, so we should use that
                  const runId = await _ctx.runMutation(
                    internal.previewRuns.enqueueFromWebhook,
                    {
                      previewConfigId: previewConfig._id,
                      teamId: previewConfig.teamId,
                      repoFullName,
                      repoInstallationId: installation,
                      prNumber,
                      prUrl,
                      prTitle,
                      prDescription,
                      headSha,
                      baseSha,
                      headRef,
                      headRepoFullName,
                      headRepoCloneUrl,
                    },
                  );

                  const existingRun = await _ctx.runQuery(
                    internal.previewRuns.getById,
                    { id: runId },
                  );

                  console.log("[preview-jobs] Preview run enqueued", {
                    runId,
                    repoFullName,
                    prNumber,
                    prUrl,
                  });

                  if (existingRun?.taskRunId) {
                    console.log("[preview-jobs] Preview run already has taskRun; skipping duplicate creation", {
                      runId,
                      taskRunId: existingRun.taskRunId,
                      status: existingRun.status,
                    });
                    if (existingRun.status === "pending") {
                      await _ctx.scheduler.runAfter(
                        0,
                        internal.preview_jobs.requestDispatch,
                        { previewRunId: runId },
                      );
                    }
                  } else {
                    // Create task and taskRun for screenshot collection
                    // The existing worker infrastructure will pick this up and process it
                    // Use "system" as fallback for legacy configs without createdByUserId
                    const previewUserId = previewConfig.createdByUserId ?? "system";
                    const taskId = await _ctx.runMutation(
                      internal.tasks.createForPreview,
                      {
                        teamId: previewConfig.teamId,
                        userId: previewUserId,
                        previewRunId: runId,
                        repoFullName,
                        prNumber,
                        prUrl,
                        headSha,
                        baseBranch: previewConfig.repoDefaultBranch,
                      },
                    );

                    const { taskRunId } = await _ctx.runMutation(
                      internal.taskRuns.createForPreview,
                      {
                        taskId,
                        teamId: previewConfig.teamId,
                        userId: previewUserId,
                        prUrl,
                        environmentId: previewConfig.environmentId,
                        newBranch: headRef,
                      },
                    );

                    // Link the taskRun to the preview run
                    await _ctx.runMutation(internal.previewRuns.linkTaskRun, {
                      previewRunId: runId,
                      taskRunId,
                    });

                    console.log("[preview-jobs] Task and taskRun created", {
                      runId,
                      taskId,
                      taskRunId,
                      repoFullName,
                      prNumber,
                    });

                    // Trigger the preview job dispatch
                    await _ctx.scheduler.runAfter(
                      0,
                      internal.preview_jobs.requestDispatch,
                      { previewRunId: runId },
                    );

                    console.log("[preview-jobs] Preview job dispatch scheduled", {
                      runId,
                    });
                  }
                } catch (error) {
                  console.error("[preview-jobs] Failed to enqueue preview run", {
                    repoFullName,
                    prNumber,
                    error,
                  });
                }
              }
            } else {
              console.log("[preview-jobs] No preview config found for repo", {
                repoFullName,
                installationId: installation,
              });
            }
          }
        } catch (err) {
          console.error("github_webhook pull_request handler failed", {
            err,
            delivery,
          });
        }
        break;
      }
      case "push": {
        try {
          const pushPayload = body as PushEvent;
          const repoFullName = String(pushPayload.repository?.full_name ?? "");
          const installation = Number(pushPayload.installation?.id ?? 0);
          if (!repoFullName || !installation) break;
          const conn = await _ctx.runQuery(
            internal.github_app.getProviderConnectionByInstallationId,
            { installationId: installation },
          );
          const teamId = conn?.teamId;
          if (!teamId) break;
          const repoPushedAt = normalizeTimestamp(
            pushPayload.repository?.pushed_at,
          );
          const headCommitAt = normalizeTimestamp(
            pushPayload.head_commit?.timestamp,
          );
          const pushedAtMillis = repoPushedAt ?? headCommitAt ?? Date.now();
          const providerRepoId =
            typeof pushPayload.repository?.id === "number"
              ? pushPayload.repository.id
              : undefined;
          if (DEBUG_FLAGS.githubWebhook) {
            console.debug("github_webhook push handler debug", {
              delivery,
              repoFullName,
              installation,
              pushedAtMillis,
              providerRepoId,
            });
          }
          await _ctx.runMutation(
            internal.github.updateRepoActivityFromWebhook,
            {
              teamId,
              repoFullName,
              pushedAt: pushedAtMillis,
              providerRepoId,
            },
          );
        } catch (err) {
          console.error("github_webhook push handler failed", {
            err,
            delivery,
          });
        }
        break;
      }
      default: {
        // Accept unknown events to avoid retries.
        break;
      }
    }
  } catch (err) {
    console.error("github_webhook dispatch failed", { err, delivery, event });
    // Swallow errors to avoid GitHub retries while we iterate
  }

  return new Response("ok", { status: 200 });
});
