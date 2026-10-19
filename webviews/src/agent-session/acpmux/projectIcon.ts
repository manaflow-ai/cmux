// Project favicons for the picker badges (ProjectBadge): the host reads a few well-known icon files
// in a project folder on this Mac and answers a small data URL (`project.icon {cwd}`,
// AgentPaneProjectIcon.swift); the page reads no file itself (CSP `img-src data:`). A remote
// project is never asked about: its folder is on another machine. Each folder is asked once per
// page; no icon, a refusal or an older host keeps the letters.
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
    .then((reply) => {
      const src = (reply as { src?: unknown } | null | undefined)?.src;
      return typeof src === "string" && src.startsWith("data:image/") ? src : null;
    })
    .catch(() => null)
    .then((src) => {
      icons.set(cwd, src);
      pending.delete(cwd);
      return src;
    });
  pending.set(cwd, request);
  return request;
}

/// The favicon of the local project at `cwd`, once the host answers; undefined for none, and for
/// `cwd` undefined (a remote or home project, which the badge never asks about).
export function useProjectIcon(cwd: string | undefined): string | undefined {
  const [src, setSrc] = useState(() => (cwd ? (icons.get(cwd) ?? undefined) : undefined));
  useEffect(() => {
    if (!cwd) {
      setSrc(undefined);
      return;
    }
    if (icons.has(cwd)) {
      setSrc(icons.get(cwd) ?? undefined);
      return;
    }
    let live = true;
    void load(cwd).then((icon) => {
      if (live) setSrc(icon ?? undefined);
    });
    return () => {
      live = false;
    };
  }, [cwd]);
  return src;
}
