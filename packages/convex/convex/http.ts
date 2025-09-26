import { httpRouter } from "convex/server";
import {
  crownEvaluate,
  crownSummarize,
  crownWorkerCheck,
  crownWorkerFinalize,
  crownWorkerComplete,
  crownWorkerScheduleStop,
  crownHealthCheck,
} from "./crown_http";
import { githubSetup } from "./github_setup";
import { githubWebhook } from "./github_webhook";
import { stackWebhook } from "./stack_webhook";

const http = httpRouter();

http.route({
  path: "/github_webhook",
  method: "POST",
  handler: githubWebhook,
});

http.route({
  path: "/stack_webhook",
  method: "POST",
  handler: stackWebhook,
});

http.route({
  path: "/api/crown/evaluate",
  method: "POST",
  handler: crownEvaluate,
});

http.route({
  path: "/api/crown/summarize",
  method: "POST",
  handler: crownSummarize,
});

http.route({
  path: "/api/crown/check",
  method: "POST",
  handler: crownWorkerCheck,
});

http.route({
  path: "/api/crown/finalize",
  method: "POST",
  handler: crownWorkerFinalize,
});

http.route({
  path: "/api/crown/complete",
  method: "POST",
  handler: crownWorkerComplete,
});

http.route({
  path: "/api/crown/schedule-stop",
  method: "POST",
  handler: crownWorkerScheduleStop,
});

http.route({
  path: "/api/crown/health",
  method: "GET",
  handler: crownHealthCheck,
});

http.route({
  path: "/github_setup",
  method: "GET",
  handler: githubSetup,
});

export default http;
