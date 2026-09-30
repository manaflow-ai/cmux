import type { Viewer } from "@mux/protocol";
import type { Env } from "./env.ts";

/** The signed-in human, or undefined. Stack Auth replaces dev identity in step 8. */
export async function authenticate(request: Request, env: Env): Promise<Viewer | undefined> {
  if (env.MUX_DEV_AUTH === "1") {
    const devUser =
      new URL(request.url).searchParams.get("dev_user") ?? request.headers.get("x-mux-dev-user");
    if (devUser && /^[a-z0-9-]{1,40}$/.test(devUser))
      return { id: `dev-${devUser}`, displayName: devUser };
  }
  return undefined;
}
