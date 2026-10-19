// Project favicons for the picker badges (ProjectBadge): the host reads a few well-known icon files
// in a project folder on this Mac and answers a small data URL (`project.icon {cwd}`,
// AgentPaneProjectIcon.swift); the page reads no file itself (CSP `img-src data:`). A remote
// project is never asked about: its folder is on another machine. Each folder's answer is kept for
// the page; no icon keeps the letters. A failed ask (an older host, the page not yet connected) is
// not kept, so the next badge asks again.
import { useEffect, useState } from "react";
import { postNative } from "./native";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

const icons = new Map<string, string | null>();
const pending = new Map<string, Promise<string | null>>();

/// Tests replace the host; replacing it forgets every answer.
export function setProjectIconHost(next: Call | undefined): void {
  call = next ?? postNative;
  icons.clear();
  pending.clear();
}

function load(cwd: string): Promise<string | null> {
  const started = pending.get(cwd);
  if (started) return started;
  const request = Promise.resolve()
    .then(() => call("project.icon", { cwd }))
    .then(
      (reply) => {
        const src = (reply as { src?: unknown } | null | undefined)?.src;
        const icon = typeof src === "string" && src.startsWith("data:image/") ? src : null;
        icons.set(cwd, icon);
        return icon;
      },
      () => null,
    )
    .finally(() => pending.delete(cwd));
  pending.set(cwd, request);
  return request;
}

/// The favicon of the local project at `cwd`, once the host answers; undefined for none, and for
/// `cwd` undefined (a remote or home project, which the badge never asks about).
export function useProjectIcon(cwd: string | undefined): string | undefined {
  // The answer with the folder it is for: a badge that moves to another folder never shows the
  // previous folder's icon while the new one loads.
  const [state, setState] = useState<{ cwd: string; src: string | null } | undefined>(() =>
    cwd && icons.has(cwd) ? { cwd, src: icons.get(cwd)! } : undefined,
  );
  useEffect(() => {
    if (!cwd || icons.has(cwd)) return;
    let live = true;
    void load(cwd).then((src) => {
      if (live) setState({ cwd, src });
    });
    return () => {
      live = false;
    };
  }, [cwd]);
  if (!cwd) return undefined;
  if (icons.has(cwd)) return icons.get(cwd) ?? undefined;
  return state?.cwd === cwd ? (state.src ?? undefined) : undefined;
}
