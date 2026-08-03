import { defaultHostedSubrouterURL } from "@/services/subrouter/constants";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const STACK_API_URL = "https://api.stack-auth.com/api/v1";

export function GET(request: Request): Response {
  const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID?.trim();
  const publishableClientKey =
    process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY?.trim();
  if (!projectId || !publishableClientKey) {
    return Response.json(
      { error: "cli_auth_unavailable" },
      {
        status: 503,
        headers: { "cache-control": "no-store" },
      },
    );
  }

  return Response.json(
    {
      version: 1,
      auth: {
        apiUrl: STACK_API_URL,
        projectId,
        publishableClientKey,
        // Start and complete the CLI login against the same deployment so the
        // confirmation page uses the Stack project that issued the login code.
        confirmUrl: new URL("/handler/cli-auth-confirm", request.url).toString(),
      },
      subrouter: {
        url:
          process.env.SUBROUTER_HOSTED_URL?.trim() ||
          defaultHostedSubrouterURL(),
      },
    },
    {
      headers: {
        "cache-control": "public, max-age=300",
      },
    },
  );
}
