// Text helpers for the New Tab rows under the field: where the typed query matched a title, and a
// page address short enough to scan in a narrow row.

/// The [start, end) ranges of `text` that each word of `query` matches (case-insensitive, every
/// occurrence), sorted and merged. An empty query matches nothing.
export function matchRanges(text: string, query: string): [number, number][] {
  const haystack = text.toLowerCase();
  const ranges: [number, number][] = [];
  for (const word of query.toLowerCase().split(/\s+/).filter(Boolean)) {
    for (let at = haystack.indexOf(word); at !== -1; at = haystack.indexOf(word, at + word.length))
      ranges.push([at, at + word.length]);
  }
  ranges.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const merged: [number, number][] = [];
  for (const range of ranges) {
    const last = merged[merged.length - 1];
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1]);
    else merged.push([range[0], range[1]]);
  }
  return merged;
}

/// `url` without its scheme and `www.`; when longer than `max`, the host, an ellipsis and the end
/// of the address (its last path segment and query), so two pages of one site stay apart. A host
/// that is itself too long ends in an ellipsis.
export function compactUrl(url: string, max = 48): string {
  const bare = url.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").replace(/^www\./i, "");
  if (bare.length <= max) return bare;
  const slash = bare.indexOf("/");
  const host = slash === -1 ? bare : bare.slice(0, slash + 1);
  if (host.length + 2 >= max) return bare.slice(0, max - 1) + "…";
  const path = slash === -1 ? "" : bare.slice(slash + 1);
  const lastSlash = path.lastIndexOf("/");
  let tail = lastSlash === -1 ? path : path.slice(lastSlash + 1);
  const room = max - host.length - 2;
  if (tail.length > room) tail = tail.slice(tail.length - room);
  return `${host}…/${tail}`;
}
