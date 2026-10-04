// A fake async file system for the path picker spike. Each listing resolves after a delay, so the
// widgets must cope with items that arrive after the query changes (the real picker's shape).
export interface Entry { name: string; path: string; dir: boolean }

const TREE: Record<string, string[]> = {
  "/": ["src/", "docs/", "README.md", "package.json"],
  "/src": ["components/", "main.tsx", "App.tsx", "styles.css"],
  "/src/components": ["Button.tsx", "Menu.tsx"],
  "/docs": ["guide.md", "api.md"],
};

export function parent(path: string): string {
  if (path === "/") return "/";
  const cut = path.lastIndexOf("/");
  return cut <= 0 ? "/" : path.slice(0, cut);
}

export async function list(path: string): Promise<Entry[]> {
  await new Promise((resolve) => setTimeout(resolve, 40));
  return (TREE[path] ?? []).map((raw) => {
    const dir = raw.endsWith("/");
    const name = dir ? raw.slice(0, -1) : raw;
    return { name, dir, path: path === "/" ? `/${name}` : `${path}/${name}` };
  });
}

export const SOURCES = ["Working tree", "Staged"] as const;
export const COMMITS = ["HEAD~1", "HEAD~2", "main"] as const;
export const TOOLS = [
  { id: "split", label: "Split view" },
  { id: "unified", label: "Unified view" },
  { id: "wrap", label: "Wrap lines" },
  { id: "collapse", label: "Collapse all files" },
] as const;

// The result line every implementation writes, so the keyboard script can check outcomes.
export function report(text: string) {
  const out = document.getElementById("result");
  if (out) out.textContent = text;
}

// `?rtl` runs the page right to left; each library gets its own direction provider (see Providers).
export const RTL = typeof location !== "undefined" && new URLSearchParams(location.search).has("rtl");
// `?nonmodal` opens Base UI menus with modal={false} (no outside-click blocking or scroll lock).
export const NONMODAL = typeof location !== "undefined" && new URLSearchParams(location.search).has("nonmodal");
