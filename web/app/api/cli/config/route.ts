import {
  defaultHostedSubrouterURL,
  hostedSubrouterBaseURL,
} from "@/services/subrouter/constants";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const DEFAULT_STACK_API_URL = "https://api.stack-auth.com/api/v1";

export function GET(request: Request): Response {
  const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID?.trim();
  const publishableClientKey =
    process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY?.trim();
  const tenantControlToken =
    process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN?.trim();
  if (!projectId || !publishableClientKey || !tenantControlToken) {
    return unavailableResponse();
  }
  let subrouterURL: string;
  try {
    subrouterURL = hostedSubrouterBaseURL(
      process.env.SUBROUTER_HOSTED_URL?.trim() ||
        defaultHostedSubrouterURL(),
    );
  } catch {
    return unavailableResponse();
  }

  return Response.json(
    {
      version: 2,
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
      subrouter: {
        url: subrouterURL,
        exchangeUrl: new URL(
          "/api/subrouter/exchange",
          request.url,
        ).toString(),
      },
    },
    {
      headers: {
        "cache-control": "public, max-age=300",
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
