import { env } from "@/app/env";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const STACK_API_URL = "https://api.stack-auth.com/api/v1";
const STACK_CONFIRM_URL = "https://cmux.com/handler/cli-auth-confirm";
const HOSTED_SUBROUTER_URL = "https://sr.cmux.dev";

export function GET(): Response {
  return Response.json(
    {
      version: 1,
      auth: {
        apiUrl: STACK_API_URL,
        projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
        publishableClientKey: env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
        confirmUrl: STACK_CONFIRM_URL,
      },
      subrouter: {
        url: env.SUBROUTER_HOSTED_URL ?? HOSTED_SUBROUTER_URL,
      },
    },
    {
      headers: {
        "cache-control": "public, max-age=300",
      },
    },
  );
}
