import { Hono, type MiddlewareHandler } from "hono";
import { requireUser, userView } from "./auth";
import type { Deps, HonoEnv, Mailer } from "./context";
import { stackProjects, dbConfigured, emailConfigured, oauthConfigured, turnConfigured, type AppEnv } from "./env";
import { ApiError, errorBody, notFound, unavailable } from "./errors";
import { repoFromEnv } from "./repo";
import { authRoutes } from "./routes/auth";
import { hostRoutes } from "./routes/hosts";
import { iceRoutes } from "./routes/ice";
import { oauthRoutes } from "./routes/oauth";
import { signalRoutes } from "./routes/signal";
import { notifyUserDeleted } from "./signal/client";

/** Sends through the Cloudflare Email Sending binding. */
export const cloudflareMailer: Mailer = async (env: AppEnv, mail) => {
  if (!emailConfigured(env)) return false;
  try {
    await env.EMAIL!.send({ from: { name: "cmux", email: env.EMAIL_FROM! }, to: mail.to, subject: mail.subject, text: mail.text, html: mail.html });
    return true;
  } catch (err) {
    console.error("email send failed", err instanceof Error ? err.message : err);
    return false;
  }
};

export const defaultDeps: Deps = {
  repo: repoFromEnv,
  now: () => Date.now(),
  fetch: (input, init) => fetch(input, init),
  mailer: cloudflareMailer,
};

export function createApp(overrides: Partial<Deps> = {}) {
  const deps: Deps = { ...defaultDeps, ...overrides };
  const app = new Hono<HonoEnv>();

  app.use("*", async (c, next) => {
    c.set("deps", deps);
    await next();
  });

  /** Routes that need the database answer 503 until it is configured. */
  const db: MiddlewareHandler<HonoEnv> = async (c, next) => {
    const repo = deps.repo(c.env);
    if (!repo) throw unavailable("database not configured");
    c.set("repo", repo);
    await next();
  };

  const v1 = new Hono<HonoEnv>();

  v1.get("/health", (c) =>
    c.json({
      ok: true,
      db: dbConfigured(c.env),
      email: emailConfigured(c.env),
      turn: turnConfigured(c.env),
      auth: Boolean(c.env.JWT_SECRET),
      stack: stackProjects(c.env).size > 0,
      stackDev: c.env.DEV_STACK_ENABLED === "true",
      oauth: { github: oauthConfigured(c.env, "github"), google: oauthConfigured(c.env, "google") },
    }),
  );

  v1.use("/auth/*", db);
  v1.use("/me", db);
  v1.use("/hosts/*", db);
  v1.use("/hosts", db);
  v1.use("/ice", db);
  v1.use("/signal", db);

  v1.route("/auth/oauth", oauthRoutes);
  v1.route("/auth", authRoutes);
  v1.route("/hosts", hostRoutes);
  v1.route("/ice", iceRoutes);
  v1.route("/signal", signalRoutes);

  v1.get("/me", requireUser, async (c) => {
    const user = await c.var.repo.getUser(c.var.principal.userId);
    if (!user) throw notFound("user not found");
    return c.json({ user: userView(user) });
  });

  v1.delete("/me", requireUser, async (c) => {
    const { userId } = c.var.principal;
    await c.var.repo.deleteUser(userId);
    await notifyUserDeleted(c.env, userId);
    return c.json({});
  });

  app.route("/v1", v1);
  app.get("/", (c) => c.json({ name: "cmux-next-mobile", api: "/v1" }));

  app.notFound((c) => c.json(errorBody("not_found", "not found"), 404));
  app.onError((err, c) => {
    if (err instanceof ApiError) return c.json(errorBody(err.code, err.message), err.status);
    console.error("unhandled", err instanceof Error ? (err.stack ?? err.message) : err);
    return c.json(errorBody("internal", "internal error"), 500);
  });
  return app;
}
