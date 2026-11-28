/**
 * Flat string search params, matching the URLs server routes and emails
 * already produce (`?team=`, `?billing=error`). TanStack's default JSON
 * search encoding would turn `?q=123` into a number and quote strings.
 */
export type FlatSearch = Record<string, string>;

export function parseFlatSearch(search: string): FlatSearch {
  return Object.fromEntries(new URLSearchParams(search));
}

export function stringifyFlatSearch(search: Record<string, unknown>): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(search)) {
    if (value === undefined || value === null || value === "") continue;
    params.set(key, String(value));
  }
  const query = params.toString();
  return query ? `?${query}` : "";
}
