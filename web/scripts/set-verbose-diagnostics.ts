// Sets or clears the verbose-diagnostics flag on one account.
//
//   bun scripts/set-verbose-diagnostics.ts <email> on|off
//
// Requires Stack server credentials in the environment (the same
// NEXT_PUBLIC_STACK_* / STACK_SECRET_SERVER_KEY set web uses; see
// scripts/load-dev-env.sh for local runs). The flag lands in the user's
// clientReadOnlyMetadata as `cmuxVerboseDiagnostics: true`. While set, every
// authenticated backend request from that account emits a structured
// `[cmux-verbose-diag]` log line, and the iOS app streams its diagnostic
// events to /api/diagnostics/ingest. Every other metadata key (cmuxPlan,
// cmuxVmPlan, cmuxReviewDemoContent, ...) is preserved.

import { getStackServerApp, isStackConfigured } from "../app/lib/stack";
import {
  setVerboseDiagnostics,
  verboseDiagnosticsEnabled,
} from "../services/account/verboseDiagnostics";

function usage(): never {
  console.error("usage: bun scripts/set-verbose-diagnostics.ts <email> on|off");
  process.exit(2);
}

async function main() {
  const [, , rawEmail, rawMode] = process.argv;
  if (!rawEmail || !rawMode) usage();
  const email = rawEmail.trim().toLowerCase();
  const mode = rawMode.trim().toLowerCase();
  if (mode !== "on" && mode !== "off") usage();
  const enabled = mode === "on";

  if (!isStackConfigured()) {
    throw new Error(
      "Stack Auth is not configured (NEXT_PUBLIC_STACK_PROJECT_ID / " +
        "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY / STACK_SECRET_SERVER_KEY)",
    );
  }
  const app = getStackServerApp();
  const users = await app.listUsers({
    query: email,
    limit: 20,
    includeAnonymous: false,
  });
  const user = users.find(
    (candidate) => (candidate.primaryEmail ?? "").trim().toLowerCase() === email,
  );
  if (!user) {
    throw new Error(`no Stack user with primary email ${email}`);
  }

  const before = verboseDiagnosticsEnabled(user.clientReadOnlyMetadata);
  const after = await setVerboseDiagnostics(user, enabled);
  console.log(
    JSON.stringify(
      {
        userId: user.id,
        email,
        verboseDiagnosticsWas: before,
        verboseDiagnosticsNow: verboseDiagnosticsEnabled(after),
        clientReadOnlyMetadata: after,
      },
      null,
      2,
    ),
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
