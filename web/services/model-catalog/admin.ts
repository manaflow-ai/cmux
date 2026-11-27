// Curator operations behind the admin routes: list the override rows, change one
// row, publish. Every mutation is audited by the route (withAdminAudit).

import { checkRow, OverrideValueError, type OverrideRow } from "./overrideRows";
import { publishCatalog, type CatalogRepo } from "./publish";

export type AdminResult = { status: number; body: Record<string, unknown> };

export async function listOverrides(repo: CatalogRepo): Promise<AdminResult> {
  const [rows, newest] = await Promise.all([repo.listOverrides(), repo.newestVersion()]);
  return {
    status: 200,
    body: {
      overrides: rows.map((row) => ({ ...row, updatedAt: row.updatedAt.toISOString() })),
      published: newest
        ? { version: newest.version, contentHash: newest.contentHash, publishedAt: newest.publishedAt.toISOString(), publishedBy: newest.publishedBy }
        : null,
    },
  };
}

/** Reads `{kind, harnessId, modelId?, value, active?}`. */
export function parseOverrideInput(input: unknown): OverrideRow | { error: string } {
  if (!input || typeof input !== "object" || Array.isArray(input)) return { error: "body must be an object" };
  const body = input as Record<string, unknown>;
  const row: OverrideRow = {
    kind: body.kind as OverrideRow["kind"],
    harnessId: typeof body.harnessId === "string" ? body.harnessId : "",
    modelId: typeof body.modelId === "string" ? body.modelId : null,
    value: (body.value ?? {}) as Record<string, unknown>,
    active: body.active === undefined ? true : body.active === true,
  };
  if (body.active !== undefined && typeof body.active !== "boolean") return { error: "active must be a boolean" };
  try {
    checkRow(row);
  } catch (error) {
    if (error instanceof OverrideValueError) return { error: error.message };
    throw error;
  }
  return row;
}

export async function saveOverride(repo: CatalogRepo, input: unknown, author: string): Promise<AdminResult> {
  const row = parseOverrideInput(input);
  if ("error" in row) return { status: 400, body: { error: "invalid_override", message: row.error } };
  const saved = await repo.upsertOverride(row, author);
  return { status: 200, body: { id: saved.id, published: false, note: "POST /api/admin/model-catalog/publish to serve it" } };
}

export async function publish(repo: CatalogRepo, author: string): Promise<AdminResult> {
  const result = await publishCatalog(repo, author);
  if (!result.ok) return { status: 422, body: { error: "publish_refused", message: result.error } };
  return {
    status: 200,
    body: { published: result.published, version: result.version.version, contentHash: result.version.contentHash },
  };
}
