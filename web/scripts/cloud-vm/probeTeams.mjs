// The sign-in service gives every new account a personal team. Deleting a
// probe's throwaway account leaves that team behind with no members, so each
// probe run used to add one empty team ("cmux prod smoke's Team") to the
// production directory, where they buried real teams in the admin search.
//
// deleteProbeUser deletes the account and then the teams it belonged to that
// are left empty. listOrphanProbeTeams finds the teams earlier runs left.

/**
 * Personal-team names of the probe accounts: `cmux <env> smoke`
 * (smoke-vm-api.mjs), `cmux <env> stress <n>` (stress-vm-api.mjs),
 * `cmux <env> startup bench` (bench-vm-startup.mjs), `cmux dogfood`
 * (dogfood-journey.mjs), `cmux Iroh production gate`
 * (scripts/lib/temporary-stack-user.mjs), and the retired `team check` and
 * `freestyle rpc smoke` probes. The admin search hides the same names
 * (web/services/admin/proGrants.ts isProbeTeamName).
 */
export const PROBE_TEAM_NAME =
  /^cmux (?:(?:prod|production|staging|dev) (?:smoke|team check|freestyle rpc smoke|stress \d+|startup bench)|dogfood|Iroh production gate)'s Team$/;

export function isProbeTeamName(displayName) {
  return typeof displayName === "string" && PROBE_TEAM_NAME.test(displayName);
}

/**
 * Deletes `user` (a server-side user of `app`), then every team it belonged
 * to that is left with no members. A team that still has a member is kept:
 * it is someone else's too. Throws only when the user delete fails; a team
 * that could not be deleted is reported in `teamsKept`.
 */
export async function deleteProbeUser(app, user) {
  let teams = [];
  try {
    teams = await user.listTeams();
  } catch {
    // Listing is best effort: the account still goes, and the orphan sweep
    // (cleanup-probe-teams.mjs) finds a team this missed.
  }
  await user.delete();
  const result = { teamsDeleted: 0, teamsKept: [] };
  for (const { id } of teams) {
    try {
      const team = await app.getTeam(id);
      if (!team) continue;
      if ((await team.listUsers()).length > 0) {
        result.teamsKept.push(id);
        continue;
      }
      await team.delete();
      result.teamsDeleted += 1;
    } catch {
      result.teamsKept.push(id);
    }
  }
  return result;
}

/**
 * Teams with a probe account's name and no members, oldest first, reading at
 * most `maxPages` directory pages of `pageSize`. Only exact probe names
 * qualify, so a person's team is never listed.
 */
export async function listOrphanProbeTeams(app, { maxPages = 50, pageSize = 100 } = {}) {
  const orphans = [];
  let scanned = 0;
  let cursor;
  for (let page = 0; page < maxPages; page += 1) {
    const teams = await app.listTeams({ query: "cmux", limit: pageSize, ...(cursor ? { cursor } : {}) });
    scanned += teams.length;
    for (const team of teams) {
      if (!isProbeTeamName(team.displayName)) continue;
      if ((await team.listUsers()).length > 0) continue;
      orphans.push(team);
    }
    cursor = teams.nextCursor ?? null;
    if (!cursor) break;
  }
  return { orphans, scanned, complete: !cursor };
}
