// Agent session avatars (Leo 2026-10-26: "upload their own if they have things from elsewhere for
// the avatars"): the person's own picture for a session, which its cards and sender chip draw in
// place of the harness mark. The host keeps it on this Mac and answers a small data URL
// (`agent.avatar {sessionId}`, AgentAvatars.swift); the chat's ⋯ menu sets and removes it
// (`agent.avatar.set`, `agent.avatar.remove`), and the host tells every pane's page of a change
// (`cmuxAcpmuxBridge.agentAvatarChanged`). An answer is kept for the page, a change is told to
// every card at once, and a failed ask (an older host, the page not yet connected) is not kept.
import { useEffect, useState } from "react";
import { postNative } from "./native";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

/// Each session's avatar: a data URL, or null for none.
const avatars = new Map<string, string | null>();
const pending = new Map<string, Promise<string | null>>();
/// Each session's change count: a read that started before a Set or Remove keeps nothing.
const changes = new Map<string, number>();
const listeners = new Set<() => void>();

/// Tests replace the host; replacing it forgets every answer.
export function setAgentAvatarHost(next: Call | undefined): void {
  call = next ?? postNative;
  avatars.clear();
  pending.clear();
  changes.clear();
}

function src(reply: unknown): string | null {
  const value = (reply as { src?: unknown } | undefined)?.src;
  return typeof value === "string" && value.startsWith("data:image/") ? value : null;
}

function changed(sessionId: string, value: string | null): void {
  changes.set(sessionId, (changes.get(sessionId) ?? 0) + 1);
  pending.delete(sessionId);
  avatars.set(sessionId, value);
  for (const listener of listeners) listener();
}

/// Asks the host for the session's avatar once at a time (exported for tests).
export function loadAgentAvatar(sessionId: string): Promise<string | null> {
  const started = pending.get(sessionId);
  if (started) return started;
  const asked = changes.get(sessionId) ?? 0;
  const request: Promise<string | null> = Promise.resolve()
    .then(() => call("agent.avatar", { sessionId }))
    .then(
      (reply) => {
        if ((changes.get(sessionId) ?? 0) !== asked) return avatars.get(sessionId) ?? null;
        const value = src(reply);
        avatars.set(sessionId, value);
        return value;
      },
      () => {
        // A failed read keeps nothing: a picture shown before a change in another pane goes, and
        // the next card that draws the session asks again.
        if ((changes.get(sessionId) ?? 0) === asked) avatars.delete(sessionId);
        return null;
      },
    )
    .finally(() => {
      if (pending.get(sessionId) === request) pending.delete(sessionId);
    });
  pending.set(sessionId, request);
  return request;
}

/// The host says session `sessionId`'s avatar was set or removed (in this pane or another): a read
/// that started before keeps nothing, and a session a card draws is asked for again; its old
/// picture stays until the answer comes, so nothing flashes.
export function agentAvatarChanged(sessionId: string): void {
  const asked = avatars.has(sessionId) || pending.has(sessionId);
  changes.set(sessionId, (changes.get(sessionId) ?? 0) + 1);
  pending.delete(sessionId);
  if (!asked) return;
  void loadAgentAvatar(sessionId).then(() => {
    for (const listener of listeners) listener();
  });
}

/// Set Avatar…: the host's open panel, then every card of the session draws the new picture.
export async function setAgentAvatar(sessionId: string): Promise<void> {
  const value = src(await call("agent.avatar.set", { sessionId }));
  if (value) changed(sessionId, value);
}

/// Remove Avatar: the session's harness mark again.
export async function removeAgentAvatar(sessionId: string): Promise<void> {
  await call("agent.avatar.remove", { sessionId });
  changed(sessionId, null);
}

/// Whether the session has an avatar the page knows of (the menu offers Remove Avatar then).
export function hasAgentAvatar(sessionId: string | undefined): boolean {
  return sessionId !== undefined && typeof avatars.get(sessionId) === "string";
}

/// Session `sessionId`'s avatar as a data URL once the host answers; undefined for none, and for
/// no session.
export function useAgentAvatar(sessionId: string | undefined): string | undefined {
  const [, redraw] = useState(0);
  useEffect(() => {
    const listener = () => redraw((count) => count + 1);
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  }, []);
  useEffect(() => {
    if (!sessionId || avatars.has(sessionId)) return;
    let live = true;
    void loadAgentAvatar(sessionId).then(() => {
      if (live) redraw((count) => count + 1);
    });
    return () => {
      live = false;
    };
  }, [sessionId]);
  return (sessionId && avatars.get(sessionId)) || undefined;
}
