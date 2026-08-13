import {
  defaultHostedSubrouterURL,
  hostedSubrouterBaseURL,
} from "@/services/subrouter/constants";


const DEFAULT_STACK_API_URL = "https://api.stack-auth.com/api/v1";

// This metadata is informational for now. Keep the legacy `version` field
// below for clients that already consume the config response, and do not gate
// the response on a client version until the released clients have had time
// to learn this contract.
const CLIENT_CONTRACT = {
  protocolVersion: 4,
  minCliVersion: "0.2.3",
  requiredFeatures: ["coderouter", "organizations"],
} as const;

export function GET(request: Request): Response {
  const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID?.trim();
  const publishableClientKey =
    process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY?.trim();
  if (!projectId || !publishableClientKey) {
    return unavailableResponse();
  }
  let subrouterUrl: string;
  try {
    subrouterUrl = hostedSubrouterBaseURL(
      process.env.SUBROUTER_HOSTED_URL?.trim() ||
        defaultHostedSubrouterURL(),
    );
  } catch {
    return unavailableResponse();
  }

  return Response.json(
    {
      version: 4,
      clientContract: CLIENT_CONTRACT,
      auth: {
        apiUrl:
          process.env.NEXT_PUBLIC_STACK_API_URL?.trim() ||
          DEFAULT_STACK_API_URL,
        projectId,
        publishableClientKey,
        // Start and complete the CLI login against the same deployment so the
        // confirmation page uses the Stack project that issued the login code.
        confirmUrl: new URL("/handler/cli-auth-confirm", request.url).toString(),
      },
      coderouter: {
        sessionUrl: new URL("/api/coderouter/session", request.url).toString(),
        accountsUrl: new URL("/api/coderouter/accounts", request.url).toString(),
        organizationsUrl: new URL(
          "/api/coderouter/organizations",
          request.url,
        ).toString(),
        openaiBaseUrl: new URL("/v1", request.url).toString(),
      },
      // Keep the hosted Subrouter fields for released sr clients while cmux
      // migrates its CodeRouter data plane to Vercel.
      subrouter: {
        url: subrouterUrl,
        exchangeUrl: new URL(
          "/api/subrouter/tenant-exchange",
          request.url,
        ).toString(),
      },
    },
    {
      headers: {
        "cache-control": "no-store",
      },
    },
  );
}

function unavailableResponse(): Response {
  return Response.json(
    { error: "cli_auth_unavailable" },
    {
      status: 503,
      headers: { "cache-control": "no-store" },
    },
  );
}
