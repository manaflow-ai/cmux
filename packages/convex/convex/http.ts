import { httpRouter } from "convex/server";
import { githubWebhook } from "./github_webhook";
import { stackWebhook } from "./stack_webhook";
import { githubSetup } from "./github_setup";

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

export default http;

http.route({
  path: "/github_setup",
  method: "GET",
  handler: githubSetup,
});
