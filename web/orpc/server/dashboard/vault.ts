import { z } from "zod";
import * as summaryRoute from "@/app/api/vault/summary/route";
import * as sessionsRoute from "@/app/api/vault/sessions/route";
import * as sessionRoute from "@/app/api/vault/sessions/[id]/route";
import * as sessionHeadRoute from "@/app/api/vault/sessions/[id]/head/route";
import * as cliAuthClientRoute from "@/app/api/vault/cli/auth/client/route";
import * as cliAuthApproveRoute from "@/app/api/vault/cli/auth/approve/route";
import { dashboardOS, requireDashboardOrigin } from "./base";
import { callRoute } from "./route-call";
import { VAULT_SESSIONS_PAGE_SIZE } from "./vault-limits";
import {
  cliAuthClientSchema,
  sessionDetailSchema,
  sessionPageSchema,
  summarySchema,
  transcriptHeadSchema,
} from "./schemas/vault";

/**
 * The Vault routes own authentication, the release flag (404 while off), and
 * telemetry, and the CLI calls them too, so these procedures run them in
 * process behind the browser origin check.
 */
const vaultOS = dashboardOS.use(requireDashboardOrigin);

const sessionId = z.uuid();

const summary = vaultOS
  .output(summarySchema)
  .handler(async ({ context }) =>
    summarySchema.parse(await callRoute(context, summaryRoute.GET, { method: "GET", path: "/api/vault/summary" }))
  );

const sessions = vaultOS
  .input(z.object({ q: z.string().max(500), cursor: z.string().max(500).nullable() }))
  .output(sessionPageSchema)
  .handler(async ({ context, input }) =>
    sessionPageSchema.parse(await callRoute(context, sessionsRoute.GET, {
      method: "GET",
      path: "/api/vault/sessions",
      search: { limit: String(VAULT_SESSIONS_PAGE_SIZE), q: input.q || null, cursor: input.cursor },
    }))
  );

const session = vaultOS
  .input(z.object({ id: sessionId }))
  .output(sessionDetailSchema)
  .handler(async ({ context, input }) =>
    sessionDetailSchema.parse(await callRoute(context, sessionRoute.GET, {
      method: "GET",
      path: `/api/vault/sessions/${input.id}`,
      params: { id: input.id },
    }))
  );

/** The first parsed batch of the transcript, so the page paints before `/content` streams. */
const transcriptHead = vaultOS
  .input(z.object({ id: sessionId }))
  .output(transcriptHeadSchema)
  .handler(async ({ context, input }) =>
    transcriptHeadSchema.parse(await callRoute(context, sessionHeadRoute.GET, {
      method: "GET",
      path: `/api/vault/sessions/${input.id}/head`,
      params: { id: input.id },
    }))
  );

const userCode = z.string().trim().toUpperCase().regex(/^[A-Z2-9]{8}$/);

/** Which client started the pending device flow for `code`. */
const cliAuthClient = vaultOS
  .input(z.object({ code: userCode }))
  .output(cliAuthClientSchema)
  .handler(async ({ context, input }) =>
    cliAuthClientSchema.parse(await callRoute(context, cliAuthClientRoute.GET, {
      method: "GET",
      path: "/api/vault/cli/auth/client",
      search: { code: input.code },
    }))
  );

const approveCliAuth = vaultOS
  .input(z.object({ userCode }))
  .output(z.object({ ok: z.literal(true) }))
  .handler(async ({ context, input }) =>
    z.object({ ok: z.literal(true) }).parse(await callRoute(context, cliAuthApproveRoute.POST, {
      method: "POST",
      path: "/api/vault/cli/auth/approve",
      body: { userCode: input.userCode },
    }))
  );

export const vaultRouter = { summary, sessions, session, transcriptHead, cliAuthClient, approveCliAuth };
