// Pure pieces of the markdown viewer dev host (plugins.ts), split out so test/dev-server.test.ts
// can cover them. Dev server only; nothing here ships.
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/// shell.html placeholder -> the bundled asset MarkdownViewerAssets.shellHTML inlines there.
export const SHELL_PLACEHOLDERS: Record<string, string> = {
  githubMarkdownCSS: "github-markdown.css",
  highlightLightCSS: "highlight-github.css",
  highlightDarkCSS: "highlight-github-dark.css",
  markedJS: "marked.min.js",
  highlightJS: "highlight.min.js",
  viewerNavigationJS: "viewer-navigation.js",
};

/// Lazy libraries in the order MarkdownWebRenderer.handleLibRequest concatenates them.
export const SHELL_LIBS: Record<string, string[]> = {
  mermaid: ["mermaid.min.js"],
  "vega-lite": ["vega.min.js", "vega-lite.min.js", "vega-embed.min.js"],
};

export function isMarkdownPath(file: string): boolean {
  return /\.(md|markdown|mdx|mdown|mkd)$/i.test(file);
}

/// Fills the shell template's {{placeholders}} with `readAsset(name)` text (inserted verbatim,
/// so `$&` in a minified bundle stays literal) and tags each <style> with its index, so a
/// stylesheet edit can replace that one style in place.
export function fillShell(template: string, readAsset: (name: string) => string): string {
  let html = template;
  for (const [key, file] of Object.entries(SHELL_PLACEHOLDERS)) {
    const text = readAsset(file);
    html = html.replaceAll(`{{${key}}}`, () => text);
  }
  // The app supplies localized strings; the shell falls back to English for missing keys.
  html = html.replaceAll("{{localizedStringsJSON}}", "{}");
  let index = 0;
  return html.replace(/<style\b/g, () => `<style data-cmux-shell-style="${index++}"`);
}

/// The shell's <style> bodies, and the HTML with those bodies removed: equal skeletons mean an
/// edit touched only styles and can hot-update.
export function splitStyles(html: string): { styles: string[]; skeleton: string } {
  const styles: string[] = [];
  const skeleton = html.replace(
    /(<style\b[^>]*>)([\s\S]*?)(<\/style>)/g,
    (_match: string, open: string, body: string, close: string) => {
      styles.push(body);
      return open + close;
    },
  );
  return { styles, skeleton };
}

export type MarkdownFiles = {
  root: string;
  file(requested: string): string | undefined;
  link(from: string, raw: string | null | undefined): string | undefined;
  /** Whether the editor may save `file`: below the root (a read-only root's files are not). */
  writable(file: string): boolean;
};

/// Resolves markdown files for the dev host: only regular markdown files whose real path is
/// below `root` (writable) or a `readOnlyRoots` entry (the editor opens them read only, as the app
/// does for files outside the workspace roots). `file(requested)` takes a page `?file=` (absolute,
/// or relative to the root; empty picks `defaultFile`); `link(from, raw)` resolves a link in an
/// allowed file the way the app's resolveMarkdownFile does, relative to that file, ignoring a
/// #fragment or ?query.
export function markdownFiles(root: string, defaultFile: string, readOnlyRoots: readonly string[] = []): MarkdownFiles {
  const realRoot = fs.realpathSync(root);
  const realReadOnly = readOnlyRoots.flatMap((entry) => {
    try {
      return [fs.realpathSync(entry)];
    } catch {
      return [];
    }
  });
  const below = (real: string, base: string) => real.startsWith(`${base}/`);
  const allowed = (candidate: string): string | undefined => {
    let real: string;
    try {
      real = fs.realpathSync(candidate);
    } catch {
      return undefined;
    }
    if (!(below(real, realRoot) || realReadOnly.some((base) => below(real, base))) || !isMarkdownPath(real)) {
      return undefined;
    }
    return fs.statSync(real).isFile() ? real : undefined;
  };
  const file = (requested: string) => allowed(path.resolve(realRoot, requested || defaultFile));
  return {
    root: realRoot,
    file,
    link(from, raw) {
      const base = file(from);
      const target = (raw ?? "").trim().replace(/[#?].*$/, "");
      if (!base || !target) return undefined;
      return allowed(path.resolve(path.dirname(base), target));
    },
    writable: (file) => below(file, realRoot),
  };
}

/// The hash the editor's save checks: SHA-256 of the file's bytes, hex (host.ts `hash`).
export function contentHash(bytes: Buffer | string): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/// A markdown file as the editor gets it, or undefined when it is gone. A file that is not valid
/// UTF-8 opens read only: its text would not save back to the same bytes.
export function readMarkdown(file: string): { text: string; hash: string; utf8: boolean } | undefined {
  let bytes: Buffer;
  try {
    bytes = fs.readFileSync(file);
  } catch {
    return undefined;
  }
  const text = bytes.toString("utf8");
  return { text, hash: contentHash(bytes), utf8: Buffer.from(text, "utf8").equals(bytes) };
}

export type SaveOutcome =
  | { ok: true; hash: string }
  | { ok: false; code: "cmux.markdown.conflict"; details: { hash: string | null; text?: string; deleted?: boolean } }
  | { ok: false; code: "cmux.markdown.read_only" };

/// `cmux.markdown.save` for the dev host: writes `text` when the file's current hash is
/// `baseHash` (null: the file must not exist), through a temporary file and a rename so a reader
/// never sees half a file. The file keeps its mode.
export function saveMarkdown(file: string, text: string, baseHash: string | null, writable: boolean): SaveOutcome {
  if (!writable) return { ok: false, code: "cmux.markdown.read_only" };
  const current = readMarkdown(file);
  if ((current?.hash ?? null) !== baseHash) {
    return {
      ok: false,
      code: "cmux.markdown.conflict",
      details: current ? { hash: current.hash, text: current.text } : { hash: null, deleted: true },
    };
  }
  const bytes = Buffer.from(text, "utf8");
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}.cmux-save-${process.pid}`);
  let mode = 0o644;
  try {
    mode = fs.statSync(file).mode & 0o7777;
  } catch {}
  fs.writeFileSync(temporary, bytes, { mode });
  fs.renameSync(temporary, file);
  return { ok: true, hash: contentHash(bytes) };
}

/// An image the markdown file references, for `<assetBase><path>`: only regular image files in
/// the file's folder or below it (diff-host.md S6), with their content type.
const IMAGE_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".avif": "image/avif",
  ".ico": "image/x-icon",
};

export function markdownAsset(
  markdownFile: string,
  relative: string,
): { file: string; contentType: string } | undefined {
  const folder = path.dirname(markdownFile);
  let real: string;
  try {
    real = fs.realpathSync(path.resolve(folder, relative));
  } catch {
    return undefined;
  }
  const contentType = IMAGE_TYPES[path.extname(real).toLowerCase()];
  if (!contentType || !real.startsWith(`${fs.realpathSync(folder)}/`) || !fs.statSync(real).isFile()) return undefined;
  return { file: real, contentType };
}

/// The diagram libraries the editor loads (`<libBase><name>.js`): the classic viewer's bundles.
export const PAGE_LIBS: Record<string, string[]> = {
  mermaid: ["mermaid.min.js"],
  vega: ["vega.min.js", "vega-lite.min.js"],
};

/// `cmux.json` (CMUX_NEXT_CONFIG_FILE moves it, as it does `agent-pane/` and `diff/languages/`).
export function cmuxConfigFile(env: NodeJS.ProcessEnv = process.env, home = os.homedir()): string {
  const override = env.CMUX_NEXT_CONFIG_FILE?.trim();
  return override ? override : path.join(home, ".config", "cmux", "cmux.json");
}

/// `text` as JSON with JSONC comments and trailing commas removed (cmux.json is JSONC).
export function stripJSONC(text: string): string {
  let out = "";
  let inString = false;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    const next = text[index + 1];
    if (inString) {
      out += char;
      if (char === "\\") out += text[++index] ?? "";
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') {
      inString = true;
      out += char;
    } else if (char === "/" && next === "/") {
      while (index < text.length && text[index] !== "\n") index++;
      out += "\n";
    } else if (char === "/" && next === "*") {
      index += 2;
      while (index < text.length && !(text[index] === "*" && text[index + 1] === "/")) index++;
      index++;
    } else out += char;
  }
  return out.replace(/,(\s*[}\]])/g, "$1");
}

/// The markdown page's look for the dev host: the `markdown` section of cmux.json and
/// `<cmux.json dir>/markdown/theme.css` (settings.ts and host.ts on the page side).
export function readMarkdownLook(configFile: string): { settings?: unknown; themeCSS: string } {
  let settings: unknown;
  try {
    settings = (JSON.parse(stripJSONC(fs.readFileSync(configFile, "utf8"))) as { markdown?: unknown }).markdown;
  } catch {
    settings = undefined;
  }
  let themeCSS = "";
  try {
    themeCSS = fs.readFileSync(path.join(path.dirname(configFile), "markdown", "theme.css"), "utf8");
  } catch {}
  return { settings, themeCSS };
}
