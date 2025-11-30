/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as apiKeys from "../apiKeys.js";
import type * as backfill from "../backfill.js";
import type * as codeReview from "../codeReview.js";
import type * as codeReviewActions from "../codeReviewActions.js";
import type * as codeReview_http from "../codeReview_http.js";
import type * as comments from "../comments.js";
import type * as containerSettings from "../containerSettings.js";
import type * as crown_actions from "../crown/actions.js";
import type * as crown from "../crown.js";
import type * as crown_http from "../crown_http.js";
import type * as environmentSnapshots from "../environmentSnapshots.js";
import type * as environments from "../environments.js";
import type * as github from "../github.js";
import type * as github_app from "../github_app.js";
import type * as github_check_runs from "../github_check_runs.js";
import type * as github_commit_statuses from "../github_commit_statuses.js";
import type * as github_deployments from "../github_deployments.js";
import type * as github_http from "../github_http.js";
import type * as github_pr_comments from "../github_pr_comments.js";
import type * as github_pr_merge_handler from "../github_pr_merge_handler.js";
import type * as github_pr_queries from "../github_pr_queries.js";
import type * as github_prs from "../github_prs.js";
import type * as github_setup from "../github_setup.js";
import type * as github_webhook from "../github_webhook.js";
import type * as github_workflows from "../github_workflows.js";
import type * as http from "../http.js";
import type * as localWorkspaces from "../localWorkspaces.js";
import type * as migrations from "../migrations.js";
import type * as previewConfigs from "../previewConfigs.js";
import type * as previewRuns from "../previewRuns.js";
import type * as previewScreenshots from "../previewScreenshots.js";
import type * as preview_jobs from "../preview_jobs.js";
import type * as preview_jobs_http from "../preview_jobs_http.js";
import type * as preview_jobs_worker from "../preview_jobs_worker.js";
import type * as preview_screenshots_http from "../preview_screenshots_http.js";
import type * as screenshots_http from "../screenshots_http.js";
import type * as seed from "../seed.js";
import type * as stack from "../stack.js";
import type * as stack_webhook from "../stack_webhook.js";
import type * as stack_webhook_actions from "../stack_webhook_actions.js";
import type * as storage from "../storage.js";
import type * as taskComments from "../taskComments.js";
import type * as taskRunLogChunks from "../taskRunLogChunks.js";
import type * as taskRuns from "../taskRuns.js";
import type * as taskRuns_http from "../taskRuns_http.js";
import type * as tasks from "../tasks.js";
import type * as teams from "../teams.js";
import type * as users_utils_getWorkerAuth from "../users/utils/getWorkerAuth.js";
import type * as users_utils_index from "../users/utils/index.js";
import type * as users from "../users.js";
import type * as workspaceConfigs from "../workspaceConfigs.js";
import type * as workspaceSettings from "../workspaceSettings.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

/**
 * A utility for referencing Convex functions in your app's API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
declare const fullApi: ApiFromModules<{
  apiKeys: typeof apiKeys;
  backfill: typeof backfill;
  codeReview: typeof codeReview;
  codeReviewActions: typeof codeReviewActions;
  codeReview_http: typeof codeReview_http;
  comments: typeof comments;
  containerSettings: typeof containerSettings;
  "crown/actions": typeof crown_actions;
  crown: typeof crown;
  crown_http: typeof crown_http;
  environmentSnapshots: typeof environmentSnapshots;
  environments: typeof environments;
  github: typeof github;
  github_app: typeof github_app;
  github_check_runs: typeof github_check_runs;
  github_commit_statuses: typeof github_commit_statuses;
  github_deployments: typeof github_deployments;
  github_http: typeof github_http;
  github_pr_comments: typeof github_pr_comments;
  github_pr_merge_handler: typeof github_pr_merge_handler;
  github_pr_queries: typeof github_pr_queries;
  github_prs: typeof github_prs;
  github_setup: typeof github_setup;
  github_webhook: typeof github_webhook;
  github_workflows: typeof github_workflows;
  http: typeof http;
  localWorkspaces: typeof localWorkspaces;
  migrations: typeof migrations;
  previewConfigs: typeof previewConfigs;
  previewRuns: typeof previewRuns;
  previewScreenshots: typeof previewScreenshots;
  preview_jobs: typeof preview_jobs;
  preview_jobs_http: typeof preview_jobs_http;
  preview_jobs_worker: typeof preview_jobs_worker;
  preview_screenshots_http: typeof preview_screenshots_http;
  screenshots_http: typeof screenshots_http;
  seed: typeof seed;
  stack: typeof stack;
  stack_webhook: typeof stack_webhook;
  stack_webhook_actions: typeof stack_webhook_actions;
  storage: typeof storage;
  taskComments: typeof taskComments;
  taskRunLogChunks: typeof taskRunLogChunks;
  taskRuns: typeof taskRuns;
  taskRuns_http: typeof taskRuns_http;
  tasks: typeof tasks;
  teams: typeof teams;
  "users/utils/getWorkerAuth": typeof users_utils_getWorkerAuth;
  "users/utils/index": typeof users_utils_index;
  users: typeof users;
  workspaceConfigs: typeof workspaceConfigs;
  workspaceSettings: typeof workspaceSettings;
}>;
declare const fullApiWithMounts: typeof fullApi;

export declare const api: FilterApi<
  typeof fullApiWithMounts,
  FunctionReference<any, "public">
>;
export declare const internal: FilterApi<
  typeof fullApiWithMounts,
  FunctionReference<any, "internal">
>;

export declare const components: {
  migrations: {
    lib: {
      cancel: FunctionReference<
        "mutation",
        "internal",
        { name: string },
        {
          batchSize?: number;
          cursor?: string | null;
          error?: string;
          isDone: boolean;
          latestEnd?: number;
          latestStart: number;
          name: string;
          next?: Array<string>;
          processed: number;
          state: "inProgress" | "success" | "failed" | "canceled" | "unknown";
        }
      >;
      cancelAll: FunctionReference<
        "mutation",
        "internal",
        { sinceTs?: number },
        Array<{
          batchSize?: number;
          cursor?: string | null;
          error?: string;
          isDone: boolean;
          latestEnd?: number;
          latestStart: number;
          name: string;
          next?: Array<string>;
          processed: number;
          state: "inProgress" | "success" | "failed" | "canceled" | "unknown";
        }>
      >;
      clearAll: FunctionReference<
        "mutation",
        "internal",
        { before?: number },
        null
      >;
      getStatus: FunctionReference<
        "query",
        "internal",
        { limit?: number; names?: Array<string> },
        Array<{
          batchSize?: number;
          cursor?: string | null;
          error?: string;
          isDone: boolean;
          latestEnd?: number;
          latestStart: number;
          name: string;
          next?: Array<string>;
          processed: number;
          state: "inProgress" | "success" | "failed" | "canceled" | "unknown";
        }>
      >;
      migrate: FunctionReference<
        "mutation",
        "internal",
        {
          batchSize?: number;
          cursor?: string | null;
          dryRun: boolean;
          fnHandle: string;
          name: string;
          next?: Array<{ fnHandle: string; name: string }>;
        },
        {
          batchSize?: number;
          cursor?: string | null;
          error?: string;
          isDone: boolean;
          latestEnd?: number;
          latestStart: number;
          name: string;
          next?: Array<string>;
          processed: number;
          state: "inProgress" | "success" | "failed" | "canceled" | "unknown";
        }
      >;
    };
  };
};
