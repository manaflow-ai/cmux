import { ORPCError } from "@orpc/server";
import { z } from "zod";
import * as apiKeysRoute from "@/app/api/coderouter/api-keys/route";
import * as apiKeyRoute from "@/app/api/coderouter/api-keys/[keyId]/route";
import * as accountsRoute from "@/app/api/coderouter/accounts/route";
import * as accountRoute from "@/app/api/coderouter/accounts/[accountId]/route";
import * as sharingRoute from "@/app/api/coderouter/accounts/[accountId]/sharing/route";
import * as transferRoute from "@/app/api/coderouter/accounts/[accountId]/transfer/route";
import * as claudeUpstreamRoute from "@/app/api/coderouter/claude-upstream/route";
import * as claudeAccountRoute from "@/app/api/coderouter/claude-upstream/[accountId]/route";
import * as subrouterAccountRoute from "@/app/api/subrouter/accounts/[accountId]/route";
import { dashboardOS, requireDashboardOrigin } from "./base";
import { callRoute } from "./route-call";
import { overview } from "./coderouter-overview";
import { apiKeyListSchema, issuedApiKeySchema } from "./schemas/coderouter";

/**
 * Coderouter authorization (team grants, the Stack access token, the hosted
 * tenant) lives in the shared loader and in the coderouter routes, which the
 * CLI also calls. These procedures add only the browser origin check, so each
 * call verifies the session once.
 */
const coderouterOS = dashboardOS.use(requireDashboardOrigin);

const teamInput = z.object({ teamId: z.string().trim().min(1).max(200) });
const accountInput = teamInput.extend({ accountId: z.string().trim().min(1).max(200) });

function teamHeader(teamId: string) {
  return { "x-cmux-team-id": teamId };
}

/** Deletes where "already gone" is what the viewer wanted. */
async function ignoringNotFound(operation: () => Promise<unknown>): Promise<null> {
  try {
    await operation();
  } catch (error) {
    if (!(error instanceof ORPCError && error.status === 404)) throw error;
  }
  return null;
}

const apiKeys = coderouterOS
  .input(teamInput)
  .output(apiKeyListSchema)
  .handler(async ({ context, input }) =>
    apiKeyListSchema.parse(await callRoute(context, apiKeysRoute.GET, {
      method: "GET",
      path: "/api/coderouter/api-keys",
      headers: teamHeader(input.teamId),
    }))
  );

const createApiKey = coderouterOS
  .input(teamInput.extend({ label: z.string().trim().min(1).max(80) }))
  .output(issuedApiKeySchema)
  .handler(async ({ context, input }) =>
    issuedApiKeySchema.parse(await callRoute(context, apiKeysRoute.POST, {
      method: "POST",
      path: "/api/coderouter/api-keys",
      headers: teamHeader(input.teamId),
      body: { label: input.label },
    }))
  );

const revokeApiKey = coderouterOS
  .input(teamInput.extend({ keyId: z.uuid() }))
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, apiKeyRoute.DELETE, {
      method: "DELETE",
      path: `/api/coderouter/api-keys/${encodeURIComponent(input.keyId)}`,
      params: { keyId: input.keyId },
      headers: teamHeader(input.teamId),
    });
    return null;
  });

const setAccountVisibility = coderouterOS
  .input(accountInput.extend({ family: z.enum(["native", "claude"]), visibility: z.enum(["private", "team"]) }))
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, sharingRoute.PATCH, {
      method: "PATCH",
      path: `/api/coderouter/accounts/${encodeURIComponent(input.accountId)}/sharing`,
      params: { accountId: input.accountId },
      headers: teamHeader(input.teamId),
      body: { family: input.family, visibility: input.visibility },
    });
    return null;
  });

const removeNativeAccount = coderouterOS
  .input(accountInput)
  .output(z.null())
  .handler(({ context, input }) =>
    ignoringNotFound(() =>
      callRoute(context, accountRoute.DELETE, {
        method: "DELETE",
        path: `/api/coderouter/accounts/${encodeURIComponent(input.accountId)}`,
        params: { accountId: input.accountId },
        headers: teamHeader(input.teamId),
      })
    )
  );

/** Moves one native account from `teamId` to `destinationTeamId`. */
const transferNativeAccount = coderouterOS
  .input(accountInput.extend({ destinationTeamId: z.string().trim().min(1).max(200) }))
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, transferRoute.POST, {
      method: "POST",
      path: `/api/coderouter/accounts/${encodeURIComponent(input.accountId)}/transfer`,
      params: { accountId: input.accountId },
      headers: teamHeader(input.teamId),
      body: { destinationTeamId: input.destinationTeamId },
    });
    return null;
  });

const addApiKeyAccount = coderouterOS
  .input(teamInput.extend({
    provider: z.enum(["openai-apikey", "openrouter-apikey"]),
    apiKey: z.string().min(1).max(4096),
    label: z.string().max(200),
  }))
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, accountsRoute.POST, {
      method: "POST",
      path: "/api/coderouter/accounts",
      headers: teamHeader(input.teamId),
      body: { provider: input.provider, apiKey: input.apiKey, ...(input.label ? { label: input.label } : {}) },
    });
    return null;
  });

/** Adds a Claude upstream: `kind` plus that kind's credential fields, validated by the route. */
const addClaudeUpstream = coderouterOS
  .input(teamInput.extend({ body: z.record(z.string(), z.string()) }))
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, claudeUpstreamRoute.POST, {
      method: "POST",
      path: "/api/coderouter/claude-upstream",
      search: { teamId: input.teamId },
      body: input.body,
    });
    return null;
  });

const setClaudeAccountState = coderouterOS
  .input(accountInput.extend({ state: z.enum(["active", "disabled"]) }))
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, claudeAccountRoute.PATCH, {
      method: "PATCH",
      path: `/api/coderouter/claude-upstream/${encodeURIComponent(input.accountId)}`,
      params: { accountId: input.accountId },
      search: { teamId: input.teamId },
      body: { state: input.state },
    });
    return null;
  });

const removeClaudeAccount = coderouterOS
  .input(accountInput)
  .output(z.null())
  .handler(({ context, input }) =>
    ignoringNotFound(() =>
      callRoute(context, claudeAccountRoute.DELETE, {
        method: "DELETE",
        path: `/api/coderouter/claude-upstream/${encodeURIComponent(input.accountId)}`,
        params: { accountId: input.accountId },
        search: { teamId: input.teamId },
      })
    )
  );

/** Removes an account held by the hosted subrouter. 404 is a failure: the subrouter owns the list. */
const removeSharedAccount = coderouterOS
  .input(accountInput)
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, subrouterAccountRoute.DELETE, {
      method: "DELETE",
      path: `/api/subrouter/accounts/${encodeURIComponent(input.accountId)}`,
      params: { accountId: input.accountId },
      search: { teamId: input.teamId },
    });
    return null;
  });

export const coderouterRouter = {
  overview,
  apiKeys,
  createApiKey,
  revokeApiKey,
  setAccountVisibility,
  removeNativeAccount,
  transferNativeAccount,
  addApiKeyAccount,
  addClaudeUpstream,
  setClaudeAccountState,
  removeClaudeAccount,
  removeSharedAccount,
};
