import type { HexclaveMirrorStore } from "./mirrorStore";
import type { HexclavePage, HexclaveSource } from "./serverApi";
import { readHexclaveUserState } from "./sync";

export type HexclaveBackfillOptions = {
  readonly source: HexclaveSource;
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
  /** Mirror rows Hexclave no longer lists, reconciled (and so removed) in this run. */
  readonly pruned: number;
  readonly dryRun: boolean;
};

/**
 * Page every Hexclave team and user into the mirror through the same
 * reconcile path the webhook uses (same locks, same tombstones), so it is
 * idempotent and safe to run while webhooks arrive. Teams go first so user
 * reconciles find fresh team rows. Mirror rows Hexclave no longer lists are
 * reconciled last, which removes them. It never revokes access or
 * invalidates identity snapshots: those are webhook side effects.
 */
export async function backfillHexclaveMirror(options: HexclaveBackfillOptions): Promise<HexclaveBackfillSummary> {
  const log = options.log ?? (() => {});
  const counts = { teams: 0, users: 0, memberships: 0, teamPermissions: 0, projectPermissions: 0, pruned: 0 };
  const seenTeams = new Set<string>();
  const seenUsers = new Set<string>();

  await forEachPage(options.source.listTeamsPage, options.pageSize, async (team) => {
    seenTeams.add(team.id);
    counts.teams += 1;
    await options.store?.reconcileTeam(team.id, () => options.source.getTeam(team.id));
  }, options.concurrency, (n) => log(`teams: ${n}`));

  await forEachPage(options.source.listUsersPage, options.pageSize, async (user) => {
    seenUsers.add(user.id);
    const state = options.store
      ? (await options.store.reconcileUser(user.id, () => readHexclaveUserState(options.source, user.id))).state
      : await readHexclaveUserState(options.source, user.id);
    if (state.kind !== "present") return;
    counts.users += 1;
    counts.memberships += state.teams.length;
    counts.teamPermissions += state.teamPermissions.length;
    counts.projectPermissions += state.projectPermissions.length;
  }, options.concurrency, (n) => log(`users: ${n}`));

  if (options.store) {
    const store = options.store;
    const mirrored = await store.listMirroredIds();
    const staleTeams = mirrored.teamIds.filter((id) => !seenTeams.has(id));
    const staleUsers = mirrored.userIds.filter((id) => !seenUsers.has(id));
    await runBounded(staleTeams, options.concurrency, (id) => store.reconcileTeam(id, () => options.source.getTeam(id)));
    await runBounded(staleUsers, options.concurrency, (id) => store.reconcileUser(id, () => readHexclaveUserState(options.source, id)));
    counts.pruned = staleTeams.length + staleUsers.length;
  }
  return { ...counts, dryRun: options.store === null };
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

/** Run `task` over `items` with at most `concurrency` in flight; the first failure stops the run. */
export async function runBounded<T>(
  items: readonly T[],
  concurrency: number,
  task: (item: T) => Promise<unknown>,
): Promise<void> {
  let next = 0;
  let failed = false;
  const worker = async () => {
    while (!failed && next < items.length) {
      const item = items[next++] as T;
      try {
        await task(item);
      } catch (error) {
        failed = true;
        throw error;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(concurrency, items.length)) }, worker));
}
