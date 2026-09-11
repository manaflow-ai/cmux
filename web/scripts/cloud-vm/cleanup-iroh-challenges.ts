import * as Effect from "effect/Effect";
import * as Cause from "effect/Cause";
import * as Option from "effect/Option";
import { createAuroraOperatorPool } from "./aurora-operator.mjs";
import { cleanupIrohChallenges, IrohChallengeCleanupError } from "./iroh-challenge-cleanup";
import { loadTargetEnv, parseWebDirAndTarget } from "./projects.mjs";

const usage = "Usage: cleanup-iroh-challenges.ts [web-dir] <staging|production> [--apply]";
const { webDir, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
if (rest.some((arg: string) => arg !== "--apply")) throw new Error(usage);

const program = Effect.acquireUseRelease(
  Effect.try(() => createAuroraOperatorPool(webDir, loadTargetEnv(project), project.label)),
  (pool) => cleanupIrohChallenges(pool, { apply: rest.includes("--apply") }).pipe(
    Effect.tap((result) => Effect.sync(() => {
      console.log(JSON.stringify({ target: project.label, ...result }));
    })),
  ),
  (pool) => Effect.promise(() => pool.end()),
);
const result = await Effect.runPromiseExit(program);
if (result._tag === "Failure") {
  // Do not render nested SDK/SQL errors: they can contain credentials or rows.
  const error = Cause.failureOption(result.cause);
  console.error(Option.isSome(error) && error.value instanceof IrohChallengeCleanupError
    ? error.value.message
    : "Iroh challenge cleanup did not complete. Check operator AWS authentication and database access; committed batches are safe to rerun.");
  process.exitCode = 1;
}
