// Project favicons for the picker badges (ProjectBadge): the host reads a few well-known icon files
// in a project folder on this Mac, then in its repository's main checkout, then its GitHub owner's
// avatar, and answers a small data URL (`project.icon {cwd}`, AgentPaneProjectIcon.swift); the page
// reads no file itself (CSP `img-src data:`). With it, or alone, comes the project's framework or
// language (`glyph`, from package.json dependencies, Package.swift, Cargo.toml and the like), which
// the badge draws when there is no image. A remote project is never asked about: its folder is on
// another machine. Each folder's answer is kept for the page; neither keeps the letters. A failed or
// empty ask (an older host, the page not yet connected, or a capability still warming) is not kept,
// so the next badge asks again.
import { useEffect, useState } from "react";
import { postNative } from "./native";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

/// The languages and frameworks the badge has a glyph for (projectGlyphs.tsx), named as the host
/// answers them (AgentPaneProjectIcon.glyph).
export const PROJECT_GLYPHS = [
  "react",
  "next",
  "nuxt",
  "remix",
  "astro",
  "svelte",
  "angular",
  "vue",
  "expo",
  "electron",
  "tauri",
  "vite",
  "typescript",
  "node",
  "bun",
  "deno",
  "swift",
  "rust",
  "python",
  "go",
  "ruby",
  "zig",
  "kotlin",
  "java",
  "php",
  "elixir",
  "dart",
  "flutter",
  "cpp",
] as const;
export type ProjectGlyphName = (typeof PROJECT_GLYPHS)[number];

/// A folder's answer: its image, its glyph, either or neither.
export type ProjectIcon = { src?: string; glyph?: ProjectGlyphName };

const icons = new Map<string, ProjectIcon>();
const pending = new Map<string, Promise<ProjectIcon>>();

/// Tests replace the host; replacing it forgets every answer.
export function setProjectIconHost(next: Call | undefined): void {
  call = next ?? postNative;
  icons.clear();
  pending.clear();
}

function load(cwd: string): Promise<ProjectIcon> {
  const started = pending.get(cwd);
  if (started) return started;
  const request = Promise.resolve()
    .then(() => call("project.icon", { cwd }))
    .then(
      (reply) => {
        const { src, glyph } = (reply ?? {}) as { src?: unknown; glyph?: unknown };
        const icon: ProjectIcon = {
          ...(typeof src === "string" && src.startsWith("data:image/") ? { src } : {}),
          ...(PROJECT_GLYPHS.includes(glyph as ProjectGlyphName) ? { glyph: glyph as ProjectGlyphName } : {}),
        };
        if (Object.keys(icon).length > 0) icons.set(cwd, icon);
        return icon;
      },
      (): ProjectIcon => ({}),
    )
    .finally(() => pending.delete(cwd));
  pending.set(cwd, request);
  return request;
}

/// The icon of the local project at `cwd`, once the host answers; empty for none, and for `cwd`
/// undefined (a remote or home project, which the badge never asks about).
export function useProjectIcon(cwd: string | undefined): ProjectIcon {
  // The answer with the folder it is for: a badge that moves to another folder never shows the
  // previous folder's icon while the new one loads.
  const [state, setState] = useState<{ cwd: string; icon: ProjectIcon } | undefined>(() =>
    cwd && icons.has(cwd) ? { cwd, icon: icons.get(cwd)! } : undefined,
  );
  useEffect(() => {
    if (!cwd || icons.has(cwd)) return;
    let live = true;
    void load(cwd).then((icon) => {
      if (live) setState({ cwd, icon });
    });
    return () => {
      live = false;
    };
  }, [cwd]);
  if (!cwd) return NO_ICON;
  if (icons.has(cwd)) return icons.get(cwd)!;
  return state?.cwd === cwd ? state.icon : NO_ICON;
}

const NO_ICON: ProjectIcon = {};
