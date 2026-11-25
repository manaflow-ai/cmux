import type { Env } from "./env";
import { ApiError } from "./errors";

/**
 * Build spaces (PROTOCOL.md, Build spaces): a tagged dev build of the Mac app, of cmux Remote and of the
 * iPhone app sends `X-Cmux-Build-Space: dev:<slug>` (its tag's slug) on every request and socket upgrade;
 * NIGHTLY, release, TestFlight and App Store builds send nothing (the default space, ""). Every DEV Mac
 * and Debug iPhone of every tag uses the one dev hub, so without spaces a tag's phone listed, and asked to
 * share, every build's Mac of the same account. Each space has its own User DO (`userObjectName`): its own
 * devices, permissions, sessions, relays and audit. The rules are the mobile Worker's
 * (cmux-next-ios/backend/src/index.ts `spaceOf`) and cloud-api's (backend/apps/api/src/build-space.ts).
 */
export const BUILD_SPACE_HEADER = "x-cmux-build-space";

/** The `ENVIRONMENT` values (wrangler.toml vars, vitest.config.ts) whose hub serves dev spaces. */
const DEV_SPACE_ENVIRONMENTS: ReadonlySet<string> = new Set(["dev", "test", "local"]);
/** `dev:` and a slug: lowercase ASCII letters, digits and inner dashes, at most 64 characters. */
const BUILD_SPACE = /^dev:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;
/** Between a dev space and the user id in a dev space's User DO name. Never in a slug or a user id. */
const SEPARATOR = "|";

/**
 * The caller's build space. No header is the default space (""). A malformed value is refused (400), never
 * read as the default space: a dev build with a broken tag must not land among NIGHTLY's devices. `dev:default`
 * is refused too: the mobile-attach scripts reserve the `default` tag for the stable instance.
 *
 * Only the environments in `DEV_SPACE_ENVIRONMENTS` serve dev spaces; every other hub, production included,
 * refuses them (403 `build_space.not_allowed`) instead of serving them or dropping the header. It is an
 * allow-list, so a missing or misspelled `ENVIRONMENT` refuses too: a dev build pointed at the production hub
 * fails on its first request, before any read, rather than listing a person's real Macs.
 */
export function spaceOf(request: Request, env: Pick<Env, "ENVIRONMENT">): string {
  const value = request.headers.get(BUILD_SPACE_HEADER);
  if (value === null) return "";
  if (!BUILD_SPACE.test(value) || value === "dev:default") {
    throw new ApiError(400, "build_space.invalid", `${BUILD_SPACE_HEADER} must be dev:<slug> (lowercase letters, digits and inner dashes, at most 64)`);
  }
  if (!DEV_SPACE_ENVIRONMENTS.has(env.ENVIRONMENT ?? "")) {
    throw new ApiError(403, "build_space.not_allowed", "dev build spaces are not served by the production device hub; use the dev hub");
  }
  return value;
}

/**
 * The name of `userId`'s User DO in `space`: the user id itself in the default space (every existing object
 * stays where it is), `dev:<slug>|<userId>` in a dev space. A hub user id is `<project>:<sub>` of
 * `[A-Za-z0-9_-]`, so no default-space name ever has the separator, and no client text names a dev space's DO.
 */
export function userObjectName(space: string, userId: string): string {
  return space ? `${space}${SEPARATOR}${userId}` : userId;
}
