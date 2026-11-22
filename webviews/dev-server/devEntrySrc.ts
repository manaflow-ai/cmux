import path from "node:path";

/// The URL a page asks this server for `file` at, for a script a plugin injects into every page:
/// under the server's `base` (Chief web serves at /c/), by its path under `root`, else through
/// `/@fs`. Without the base, Chief web answered every injected script 404, and cmux Live's guard
/// took each failed load for a stopped server and reloaded the page.
export function devEntrySrc(config: { root: string; base: string }, file: string): string {
  const relative = path.relative(config.root, file);
  const served =
    relative.startsWith("..") || path.isAbsolute(relative) ? `@fs${file}` : relative.split(path.sep).join("/");
  return `${devBase(config.base)}${served}`;
}

/// `base` as a path that ends in `/`, for a URL this server serves.
export function devBase(base: string): string {
  const absolute = base.startsWith("/") ? base : "/";
  return absolute.endsWith("/") ? absolute : `${absolute}/`;
}
