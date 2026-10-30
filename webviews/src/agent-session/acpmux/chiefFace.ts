// A Chief as an agent chat draws it (manaflow-ai/cmux#27914): a message a Chief's turn sent this
// chat names the Chief by its participant id (acpmux `fromChief`), and its line shows the name and
// avatar the sidebar and Home show for that Chief, never the turn's session name
// (`optchat-<home>-<n>`) with a robot. The host answers `chief.face {chief}` with `name`, and `src`
// (a small data URL) or `text` (a text avatar: letters or an emoji) (HomeService+AgentPageFace.swift).
// An answer is kept for the page; a failed ask (an older host, the page not yet connected) is not.
import { useEffect, useSyncExternalStore } from "react";
import { postNative } from "./native";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

/// What the page draws for a Chief: its name, and its picture or its text avatar.
export type ChiefFace = { name?: string; src?: string; text?: string };

const faces = new Map<string, ChiefFace>();
const pending = new Map<string, Promise<ChiefFace | undefined>>();
const listeners = new Set<() => void>();

/// Tests replace the host; replacing it forgets every answer.
export function setChiefFaceHost(next: Call | undefined): void {
  call = next ?? postNative;
  faces.clear();
  pending.clear();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function face(reply: unknown): ChiefFace {
  const value = (reply ?? {}) as Record<string, unknown>;
  const text = (key: string) => (typeof value[key] === "string" && (value[key] as string).trim()) || undefined;
  const src = text("src");
  return {
    ...(text("name") && { name: text("name") }),
    ...(src?.startsWith("data:image/") && { src }),
    ...(text("text") && { text: text("text") }),
  };
}

/// Asks the host for Chief `chief`'s face once at a time (exported for tests).
export function loadChiefFace(chief: string): Promise<ChiefFace | undefined> {
  const started = pending.get(chief);
  if (started) return started;
  const request = Promise.resolve()
    .then(() => call("chief.face", { chief }))
    .then(
      (reply) => {
        const value = face(reply);
        faces.set(chief, value);
        for (const listener of listeners) listener();
        return value;
      },
      () => undefined,
    )
    .finally(() => {
      if (pending.get(chief) === request) pending.delete(chief);
    });
  pending.set(chief, request);
  return request;
}

/// Chief `chief`'s face once the host answers; undefined before then, and for no Chief.
export function useChiefFace(chief: string | undefined): ChiefFace | undefined {
  const value = useSyncExternalStore(subscribe, () => (chief ? faces.get(chief) : undefined));
  useEffect(() => {
    if (chief && !faces.has(chief)) void loadChiefFace(chief);
  }, [chief]);
  return value;
}
