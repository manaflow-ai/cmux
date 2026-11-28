import type { HexclaveMirrorStore } from "./mirrorStore";
import type { HexclavePage, HexclaveServerTeam, HexclaveSource } from "./serverApi";
import { readHexclaveUserState } from "./sync";

export type HexclaveBackfillOptions = {
  /** Bulk reads, made outside any lock; may retry with backoff. */
  readonly source: HexclaveSource;
  /** Reads made under a mirror lock (the prune pass); single attempt. Defaults to `source`. */
  readonly reconcileSource?: HexclaveSource;
  /** Null for a dry run: every Hexclave read is still made and schema-validated, nothing is written. */
  readonly store: HexclaveMirrorStore | null;
  readonly concurrency: number;
  readonly pageSize: number;
  readonly log?: (message: string) => void;
};

export type HexclaveBackfillSummary = {
  readonly teams: number;
  readonly users: number;
  readonly memberships: number;
  readonly teamPermissions: number;
  readonly projectPermissions: number;
  /** Entities skipped because a webhook wrote them from a fresher read during the run. */
  readonly skippedFresher: number;
  /** Mirror rows Hexclave no longer lists, reconciled (and so removed) in this run. */
  readonly pruned: number;
  readonly dryRun: boolean;
};

/**
 * Fill the mirror from bulk Hexclave reads instead of per-user reads:
 *
 * - teams and users: their paged lists (validated server objects, written as is);
 * - memberships: each team's paged member list (Hexclave has no bulk
 *   membership list and users carry no team list), one call per team page;
 * - team and project permissions: one unpaged project-wide call each.
 *
 * The snapshot is read before any lock, so each write skips an entity that a
 * webhook reconcile wrote or tombstoned after the snapshot started (its read
 * is fresher). Mirror rows Hexclave no longer lists are then reconciled one by
 * one through the webhook path, which removes them. It is idempotent, safe
 * while webhooks arrive, and never revokes access or invalidates snapshots.
 */
export async function backfillHexclaveMirror(options: HexclaveBackfillOptions): Promise<HexclaveBackfillSummary> {
  const log = options.log ?? (() => {});
  const { source, store, concurrency, pageSize } = options;
  const snapshotStartedAt = new Date();
  const counts = { teams: 0, users: 0, memberships: 0, teamPermissions: 0, projectPermissions: 0, skippedFresher: 0, pruned: 0 };
  const skipUnlessApplied = (applied: boolean) => { if (!applied) counts.skippedFresher += 1; };

  const teams = new Map<string, HexclaveServerTeam>();
  await forEachPage((cursor, limit) => source.listTeamsPage(cursor, limit), pageSize, async (team) => {
    teams.set(team.id, team);
    if (store) skipUnlessApplied(await store.applySnapshotTeam(team, snapshotStartedAt));
  }, concurrency, (n) => log(`teams: ${n}`));
  counts.teams = teams.size;

  const teamsByUser = new Map<string, HexclaveServerTeam[]>();
  await runBounded([...teams.values()], concurrency, (team) =>
    forEachPage((cursor, limit) => source.listTeamMembersPage(team.id, cursor, limit), MEMBER_PAGE_SIZE, async (member) => {
      const list = teamsByUser.get(member.id) ?? [];
      list.push(team);
      teamsByUser.set(member.id, list);
      counts.memberships += 1;
    }, 1, () => {}));
  log(`memberships: ${counts.memberships}`);

  const [teamPermissions, projectPermissions] = await Promise.all([
    source.listAllTeamPermissions(),
    source.listAllProjectPermissions(),
  ]);
  counts.teamPermissions = teamPermissions.length;
  counts.projectPermissions = projectPermissions.length;
  const teamPermissionsByUser = groupByUser(teamPermissions);
  const projectPermissionsByUser = groupByUser(projectPermissions);

  const seenUsers = new Set<string>();
  await forEachPage((cursor, limit) => source.listUsersPage(cursor, limit), pageSize, async (user) => {
    seenUsers.add(user.id);
    if (!store) return;
    skipUnlessApplied(await store.applySnapshotUser({
      kind: "present",
      user,
      teams: teamsByUser.get(user.id) ?? [],
      teamPermissions: teamPermissionsByUser.get(user.id) ?? [],
      projectPermissions: projectPermissionsByUser.get(user.id) ?? [],
    }, snapshotStartedAt));
  }, concurrency, (n) => log(`users: ${n}`));
  counts.users = seenUsers.size;

  if (store) {
    const mirrored = await store.listMirroredIds();
    const staleTeams = mirrored.teamIds.filter((id) => !teams.has(id));
    const staleUsers = mirrored.userIds.filter((id) => !seenUsers.has(id));
    const locked = options.reconcileSource ?? source;
    await runBounded(staleTeams, concurrency, (id) => store.reconcileTeam(id, () => locked.getTeam(id)));
    await runBounded(staleUsers, concurrency, (id) => store.reconcileUser(id, () => readHexclaveUserState(locked, id)));
    counts.pruned = staleTeams.length + staleUsers.length;
  }
  return { ...counts, dryRun: store === null };
}

/** Hexclave's maximum page size for user lists. */
const MEMBER_PAGE_SIZE = 1000;

function groupByUser<T extends { readonly user_id: string }>(items: readonly T[]): Map<string, T[]> {
  const grouped = new Map<string, T[]>();
  for (const item of items) {
    const list = grouped.get(item.user_id) ?? [];
    list.push(item);
    grouped.set(item.user_id, list);
  }
  return grouped;
}

async function forEachPage<T>(
  list: (cursor: string | null, limit: number) => Promise<HexclavePage<T>>,
  pageSize: number,
  visit: (item: T) => Promise<void>,
  concurrency: number,
  progress: (count: number) => void,
): Promise<void> {
  let cursor: string | null = null;
  let count = 0;
  do {
    const page: HexclavePage<T> = await list(cursor, pageSize);
    await runBounded(page.items, concurrency, visit);
    count += page.items.length;
    progress(count);
    cursor = page.nextCursor;
  } while (cursor);
}

/**
 * Run `task` over `items` with at most `concurrency` in flight. The first
 * failure stops new work; the call settles only after every in-flight task
 * has, then throws that failure.
 */
export async function runBounded<T>(
  items: readonly T[],
  concurrency: number,
  task: (item: T) => Promise<unknown>,
): Promise<void> {
  let next = 0;
  let failure: { readonly error: unknown } | null = null;
  const worker = async () => {
    while (!failure && next < items.length) {
      const item = items[next++] as T;
      try {
        await task(item);
      } catch (error) {
        failure ??= { error };
      }
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(concurrency, items.length)) }, worker));
  if (failure) throw (failure as { readonly error: unknown }).error;
}
