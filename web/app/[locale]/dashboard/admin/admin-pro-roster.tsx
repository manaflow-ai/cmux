import {
  loadProListSnapshotWithin,
  type ProListSnapshot,
} from "@/services/admin/proList";

import { AdminProList } from "./admin-pro-list";

/**
 * Server component rendered inside a Suspense boundary: the rest of the admin
 * page streams first, and the roster arrives when its bounded database read
 * completes. Any failure or timeout renders the client list in its retry
 * state instead of holding the page.
 */
export async function AdminProRoster() {
  let snapshot: ProListSnapshot | null = null;
  try {
    snapshot = await loadProListSnapshotWithin();
  } catch (error) {
    console.error("admin.pro_list.initial_load_failed", {
      failure: error instanceof Error ? error.name : "unknown",
    });
  }
  return <AdminProList initialSnapshot={snapshot} />;
}
