// The scheduled step: store a new models.dev snapshot when its content changed,
// then publish (a new catalog version only when the served body changed).

import { ingestFeed, publishCatalog, type CatalogRepo } from "./publish";
import { fetchFeed } from "./upstream";

export async function runCatalogCron(
  repo: CatalogRepo,
  options: { loadFeed?: () => Promise<unknown>; now?: () => Date } = {},
): Promise<Record<string, unknown>> {
  const feed = await (options.loadFeed ?? (() => fetchFeed()))();
  const { snapshot, inserted } = await ingestFeed(repo, feed, (options.now ?? (() => new Date()))());
  const published = await publishCatalog(repo, "cron");
  if (!published.ok) return { ok: false, snapshotId: snapshot.id, newSnapshot: inserted, error: published.error };
  return { ok: true, snapshotId: snapshot.id, newSnapshot: inserted, version: published.version.version, published: published.published };
}
