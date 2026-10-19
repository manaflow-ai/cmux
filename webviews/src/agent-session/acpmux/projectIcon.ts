// Project favicons for the picker badges (ProjectBadge): the host reads a few well-known icon files
// in a project folder on this Mac and answers a small data URL (`project.icon {cwd}`,
// AgentPaneProjectIcon.swift); the page reads no file itself (CSP `img-src data:`). A project with
// no favicon answers the language its marker files name instead (`Package.swift`: `swift`), whose
// icon the badge draws. A remote project is never asked about: its folder is on another machine.
// Each folder's answer is kept for the page; no answer keeps the letters. A failed ask (an older
// host, the page not yet connected) is not kept, so the next badge asks again.
import { useEffect, useState } from "react";
import { postNative } from "./native";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

/// What the host found for a folder: its favicon, else its language; either may be absent.
export type ProjectArt = { src?: string; language?: string };

const NONE: ProjectArt = {};
const answers = new Map<string, ProjectArt>();
const pending = new Map<string, Promise<ProjectArt>>();

/// Tests replace the host; replacing it forgets every answer.
export function setProjectIconHost(next: Call | undefined): void {
  call = next ?? postNative;
  answers.clear();
  pending.clear();
}

function read(reply: unknown): ProjectArt {
  const { src, language } = (reply ?? {}) as { src?: unknown; language?: unknown };
  const art: ProjectArt = {};
  if (typeof src === "string" && src.startsWith("data:image/")) art.src = src;
  if (typeof language === "string" && /^[a-z0-9-]{1,32}$/.test(language)) art.language = language;
  return art.src || art.language ? art : NONE;
}

function load(cwd: string): Promise<ProjectArt> {
  const started = pending.get(cwd);
  if (started) return started;
  const request = Promise.resolve()
    .then(() => call("project.icon", { cwd }))
    .then(
      (reply) => {
        const art = read(reply);
        answers.set(cwd, art);
        return art;
      },
      () => NONE,
    )
    .finally(() => pending.delete(cwd));
  pending.set(cwd, request);
  return request;
}

/// The favicon and language of the local project at `cwd`, once the host answers; empty for none,
/// and for `cwd` undefined (a remote or home project, which the badge never asks about).
export function useProjectArt(cwd: string | undefined): ProjectArt {
  // The answer with the folder it is for: a badge that moves to another folder never shows the
  // previous folder's icon while the new one loads.
  const [state, setState] = useState<{ cwd: string; art: ProjectArt } | undefined>(() =>
    cwd && answers.has(cwd) ? { cwd, art: answers.get(cwd)! } : undefined,
  );
  useEffect(() => {
    if (!cwd || answers.has(cwd)) return;
    let live = true;
    void load(cwd).then((art) => {
      if (live) setState({ cwd, art });
    });
    return () => {
      live = false;
    };
  }, [cwd]);
  if (!cwd) return NONE;
  if (answers.has(cwd)) return answers.get(cwd)!;
  return state?.cwd === cwd ? state.art : NONE;
}
