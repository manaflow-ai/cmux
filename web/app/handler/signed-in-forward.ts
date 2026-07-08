import { headers } from "next/headers";
import { stackServerApp } from "../lib/stack";
import { resolveSignedInForwardTarget } from "../lib/signed-in-forward";

export async function signedInForwardTargetForRequest(
  pathSegments: string[],
  searchParams: Record<string, string | string[] | undefined>,
): Promise<string | null> {
  const app = stackServerApp;
  if (!app) return null;

  const requestHeaders = await headers();
  return resolveSignedInForwardTarget({
    pathSegments,
    searchParams,
    requestHost: requestHeaders.get("host"),
    getUser: () => app.getUser({ or: "return-null" }),
  });
}
