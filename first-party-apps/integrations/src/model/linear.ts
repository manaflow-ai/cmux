/** The stable fields the Linear teams command returns to callers. */
export interface LinearTeam {
  readonly id: string
  readonly key: string
  readonly name: string
}

export interface LinearTeamsResult {
  readonly teams: ReadonlyArray<LinearTeam>
}

const nonEmptyText = (value: unknown): string | null => {
  if (typeof value !== "string") return null
  const text = value.trim()
  return text ? text : null
}

/**
 * Validate and minimize the provider response before returning it from an app
 * command. The gateway owns the response, so this boundary also prevents
 * provider-specific fields from accidentally becoming part of the app API.
 */
export function normalizeTeams(value: unknown): LinearTeamsResult {
  if (!value || typeof value !== "object" || !Array.isArray((value as { teams?: unknown }).teams)) throw new TypeError("Linear teams response must contain a teams array")

  const teams: LinearTeam[] = []
  const seen = new Set<string>()
  for (const row of (value as { teams: ReadonlyArray<unknown> }).teams) {
    if (!row || typeof row !== "object") continue
    const record = row as { id?: unknown; key?: unknown; name?: unknown }
    const id = nonEmptyText(record.id)
    const key = nonEmptyText(record.key)
    const name = nonEmptyText(record.name)
    if (!id || !key || !name || seen.has(id)) continue
    seen.add(id)
    teams.push({ id, key, name })
  }
  return { teams }
}
