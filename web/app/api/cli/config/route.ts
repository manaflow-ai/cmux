import { DEFAULT_HOSTED_SUBROUTER_URL } from "@/services/subrouter/constants";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const STACK_API_URL = "https://api.stack-auth.com/api/v1";
// CLI approval always uses the canonical cmux.com page so local development
// and preview config endpoints authenticate against the production Stack
// project and browser session.
const STACK_CONFIRM_URL = "https://cmux.com/handler/cli-auth-confirm";

export function GET(): Response {
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
        confirmUrl: STACK_CONFIRM_URL,
      },
      subrouter: {
        url:
          process.env.SUBROUTER_HOSTED_URL?.trim() ||
          DEFAULT_HOSTED_SUBROUTER_URL,
      },
    },
    {
      headers: {
        "cache-control": "public, max-age=300",
      },
    },
  );
}
