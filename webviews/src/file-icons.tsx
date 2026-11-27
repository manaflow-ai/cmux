import { createFileTreeIconResolver, getBuiltInSpriteSheet } from "@pierre/trees";

/**
 * Language icons for diff file headers, resolved by the same @pierre/trees icon
 * set the files sidebar uses so a file shows the same glyph and color in both
 * places. The tree paints its icons inside its shadow root; the headers are
 * light DOM slotted into Pierre's diff header, so the built-in sprite sheet is
 * mounted once in the document and each header `<use>`s a symbol from it.
 */
const iconSet = "complete" as const;
const resolver = createFileTreeIconResolver(iconSet);
const spriteAttribute = "data-cmux-file-icon-sprite";

/**
 * Hue for each built-in icon token, mirroring the
 * `--trees-file-icon-color-<token>` defaults of @pierre/trees. Tokens without
 * an entry use the muted header color.
 */
const tokenHues: Readonly<Record<string, string>> = {
  astro: "purple",
  babel: "yellow",
  bash: "green",
  biome: "blue",
  bootstrap: "indigo",
  browserslist: "yellow",
  bun: "mauve",
  c: "blue",
  claude: "orange",
  cpp: "blue",
  css: "indigo",
  database: "purple",
  docker: "blue",
  eslint: "indigo",
  go: "cyan",
  graphql: "pink",
  html: "orange",
  image: "pink",
  javascript: "yellow",
  json: "orange",
  markdown: "green",
  mcp: "teal",
  npm: "red",
  postcss: "red",
  prettier: "teal",
  python: "blue",
  react: "cyan",
  ruby: "red",
  rust: "orange",
  sass: "pink",
  svelte: "red",
  svg: "orange",
  svgo: "green",
  swift: "orange",
  table: "teal",
  tailwind: "cyan",
  terraform: "indigo",
  typescript: "blue",
  vite: "purple",
  vscode: "blue",
  vue: "green",
  wasm: "indigo",
  webpack: "blue",
  yml: "red",
  zig: "orange",
  zip: "orange",
};

export type ResolvedFileIcon = { hue: string | undefined; symbol: string; token: string | undefined };

export function resolveFileIcon(path: string): ResolvedFileIcon {
  const icon = resolver.resolveIcon("file-tree-icon-file", path);
  return { hue: icon.token == null ? undefined : tokenHues[icon.token], symbol: icon.name, token: icon.token };
}

function ensureSpriteSheet(): void {
  if (typeof document === "undefined" || document.querySelector(`[${spriteAttribute}]`) != null) {
    return;
  }
  const host = document.createElement("div");
  host.setAttribute(spriteAttribute, "");
  host.setAttribute("aria-hidden", "true");
  host.style.cssText = "position:absolute;width:0;height:0;overflow:hidden";
  host.innerHTML = getBuiltInSpriteSheet(iconSet);
  document.body.append(host);
}

export function FileIcon({ path }: { path: string }) {
  ensureSpriteSheet();
  const icon = resolveFileIcon(path);
  return (
    <svg
      className="cmux-file-icon"
      data-icon-token={icon.token}
      data-icon-hue={icon.hue}
      viewBox="0 0 16 16"
      width="16"
      height="16"
      aria-hidden="true"
    >
      <use href={`#${icon.symbol}`} />
    </svg>
  );
}
