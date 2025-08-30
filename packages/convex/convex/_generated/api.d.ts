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
import type * as comments from "../comments.js";
import type * as containerSettings from "../containerSettings.js";
import type * as crown from "../crown.js";
import type * as github from "../github.js";
import type * as github_app from "../github_app.js";
import type * as github_setup from "../github_setup.js";
import type * as github_webhook from "../github_webhook.js";
import type * as http from "../http.js";
import type * as stack from "../stack.js";
import type * as stack_webhook from "../stack_webhook.js";
import type * as storage from "../storage.js";
import type * as taskRunLogChunks from "../taskRunLogChunks.js";
import type * as taskRuns from "../taskRuns.js";
import type * as tasks from "../tasks.js";
import type * as teams from "../teams.js";
import type * as users_utils from "../users/utils.js";
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
  comments: typeof comments;
  containerSettings: typeof containerSettings;
  crown: typeof crown;
  github: typeof github;
  github_app: typeof github_app;
  github_setup: typeof github_setup;
  github_webhook: typeof github_webhook;
  http: typeof http;
  stack: typeof stack;
  stack_webhook: typeof stack_webhook;
  storage: typeof storage;
  taskRunLogChunks: typeof taskRunLogChunks;
  taskRuns: typeof taskRuns;
  tasks: typeof tasks;
  teams: typeof teams;
  "users/utils": typeof users_utils;
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

export declare const components: {};
