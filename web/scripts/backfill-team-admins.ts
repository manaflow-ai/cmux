#!/usr/bin/env bun
/**
 * Find teams with no `team_admin` holder and propose an admin for each.
 *
 * The iOS Worker (cmux-next-ios/backend, `POST /v1/teams`) created teams
 * without granting the creator `team_admin`, so those teams cannot be renamed,
 * deleted or billed from the web. A team with exactly one member gets that
 * member as its proposed admin; every other orphan is listed as needing a
 * person to choose.
 *
 * Usage, from web/ (dry run is the default and only reads):
 *
 *   NEXT_PUBLIC_STACK_PROJECT_ID=<project id> \
 *   STACK_SECRET_SERVER_KEY=<server key> \
 *   bun scripts/backfill-team-admins.ts [--concurrency 4] [--page-size 200] [--apply]
 *
 * `--apply` grants `team_admin` to each proposed admin, after re-reading the
 * team and skipping it if its sole member changed. Run `--apply` only with an
 * operator's approval for the target project. Output is team ids, user ids and
 * counts; it never prints keys, emails or team names.
 */
import { parseArgs } from "node:util";
import { createHexclaveServerApi } from "../services/auth/hexclave/serverApi";
import { stackApiBaseURL } from "../services/auth/stackApiBaseURL";
import { TEAM_ADMIN_PERMISSION } from "../services/teams/permissions";
import { applyTeamAdminProposals, findTeamsWithoutAdmin } from "../services/teams/adminBackfill";

function boundedInteger(raw: string | undefined, name: string, fallback: number, max: number): number {
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1 || value > max) throw new Error(`--${name} must be an integer from 1 to ${max}`);
  return value;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      apply: { type: "boolean", default: false },
      concurrency: { type: "string" },
      "page-size": { type: "string" },
    },
    strict: true,
  });
  const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID?.trim();
  const secretServerKey = process.env.STACK_SECRET_SERVER_KEY?.trim();
  if (!projectId || !secretServerKey) {
    throw new Error("NEXT_PUBLIC_STACK_PROJECT_ID and STACK_SECRET_SERVER_KEY are required");
  }
  const source = createHexclaveServerApi({ projectId, secretServerKey, retries: 4 });
  const report = await findTeamsWithoutAdmin({
    source,
    concurrency: boundedInteger(values.concurrency, "concurrency", 4, 16),
    // Team pages are capped at 200.
    pageSize: boundedInteger(values["page-size"], "page-size", 200, 200),
    log: (message) => console.error(`[team-admin-backfill] ${message}`),
  });
  const proposals = report.orphans.filter((orphan) => orphan.action === "grant");
  const needsHuman = report.orphans.filter((orphan) => orphan.action === "needs_human");

  let applied: Awaited<ReturnType<typeof applyTeamAdminProposals>> | null = null;
  if (values.apply) {
    // The same project and server key as the scan, so --apply needs nothing
    // beyond the two variables above (the web app's env is never loaded).
    const grant = async (userId: string, teamId: string): Promise<void> => {
      const base = stackApiBaseURL().replace(/\/+$/u, "");
      const root = /\/api\/v1$/u.test(base) ? base : `${base}/api/v1`;
      const response = await fetch(
        `${root}/team-permissions/${encodeURIComponent(teamId)}/${encodeURIComponent(userId)}/${TEAM_ADMIN_PERMISSION}`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-hexclave-access-type": "server",
            "x-hexclave-project-id": projectId,
            "x-hexclave-secret-server-key": secretServerKey,
          },
          body: "{}",
          signal: AbortSignal.timeout(10_000),
        },
      );
      await response.body?.cancel();
      if (!response.ok) throw new Error(`team_admin grant failed (${response.status})`);
    };
    applied = await applyTeamAdminProposals(proposals, { source, grant });
  }

  console.log(JSON.stringify({
    mode: values.apply ? "apply" : "dry-run",
    projectId,
    teamsScanned: report.teamsScanned,
    proposals: proposals.map(({ teamId, proposedAdminUserId }) => ({ teamId, proposedAdminUserId })),
    needsHuman: needsHuman.map(({ teamId, memberCount }) => ({ teamId, memberCount })),
    ...(applied ? { applied } : {}),
  }, null, 2));
  if (applied?.some((outcome) => outcome.result === "failed")) process.exitCode = 1;
}

await main();
