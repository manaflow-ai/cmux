// Pure pieces of the markdown viewer dev host (plugins.ts), split out so test/dev-server.test.ts
// can cover them. Dev server only; nothing here ships.
import fs from "node:fs";
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
};

/// Resolves markdown files for the dev host: only regular markdown files whose real path is
/// below `root`. `file(requested)` takes a page `?file=` (absolute, or relative to the root;
/// empty picks `defaultFile`); `link(from, raw)` resolves a link in an allowed file the way the
/// app's resolveMarkdownFile does, relative to that file, ignoring a #fragment or ?query.
export function markdownFiles(root: string, defaultFile: string): MarkdownFiles {
  const realRoot = fs.realpathSync(root);
  const allowed = (candidate: string): string | undefined => {
    let real: string;
    try {
      real = fs.realpathSync(candidate);
    } catch {
      return undefined;
    }
    if (!real.startsWith(`${realRoot}/`) || !isMarkdownPath(real)) return undefined;
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
  };
}
