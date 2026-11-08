// Sets or clears the App Review demonstration-content flag on one account.
//
//   bun scripts/set-review-demo-content.ts <email> on|off
//
// Requires Stack server credentials in the environment (the same
// NEXT_PUBLIC_STACK_* / STACK_SECRET_SERVER_KEY set web uses; see
// scripts/load-dev-env.sh for local runs). The flag lands in the user's
// clientReadOnlyMetadata as `cmuxReviewDemoContent: true`; the iOS app reads
// it at sign-in and shows the demonstration computer alongside any real Macs.
// Every other metadata key (cmuxPlan, cmuxVmPlan, ...) is preserved.

import { getStackServerApp, isStackConfigured } from "../app/lib/stack";
import {
  reviewDemoContentEnabled,
  setReviewDemoContent,
} from "../services/account/reviewDemoContent";

function usage(): never {
  console.error("usage: bun scripts/set-review-demo-content.ts <email> on|off");
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

  const before = reviewDemoContentEnabled(user.clientReadOnlyMetadata);
  const after = await setReviewDemoContent(user, enabled);
  console.log(
    JSON.stringify(
      {
        userId: user.id,
        email,
        demoContentWas: before,
        demoContentNow: reviewDemoContentEnabled(after),
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
