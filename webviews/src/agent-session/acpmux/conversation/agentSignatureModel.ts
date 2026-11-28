// The agent dot signature (appearance.agentSignature, off by default): a small particle glyph made
// from the chat's session id, drawn before the running line's words (AgentSignature.tsx). Leo
// (2026-11-19): "all of them" and "some of them maybe just as customizations lol if it affects
// default looks", so it changes nothing unless the person turns it on. acpmux computes the glyph
// (cmux-wallpaper signature.rs, `session/signature`), one source for every surface; the pane asks
// only while the setting is on, once per id, and keeps the answer for the page's life.
import { createContext, useContext, useEffect, useState, useSyncExternalStore } from "react";

export type SignatureDot = { x: number; y: number; r: number; phase: number };
export type SignatureGlyph = { seed: number; variant: string; accent: string; drift: number; dots: SignatureDot[] };

/// How the line reaches acpmux: the pane's own chat and the runtime's request path (App.tsx).
export type AgentSignatureSource = {
  sessionId: string;
  fetch: (sessionIds: string[]) => Promise<unknown>;
};

/// A source for one subtree (tests, the gallery); the pane's own chat is `setAgentSignatureSource`.
export const AgentSignatureContext = createContext<AgentSignatureSource | null>(null);

let on = false;
let paneSource: AgentSignatureSource | null = null;
const listeners = new Set<() => void>();

/// The host pushed the theme (`agentSignature`): only `true` turns the glyph on.
export function configureAgentSignature(value: unknown): void {
  const next = value === true;
  if (next === on) return;
  on = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => on;

export const useAgentSignatureOn = (): boolean => useSyncExternalStore(subscribe, snapshot, snapshot);

const paneSnapshot = () => paneSource;

/// The page's pane names its chat (App.tsx); the returned cleanup clears it again.
export function setAgentSignatureSource(next: AgentSignatureSource): () => void {
  paneSource = next;
  for (const listener of listeners) listener();
  return () => {
    if (paneSource !== next) return;
    paneSource = null;
    for (const listener of listeners) listener();
  };
}

const unit = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

/// One glyph from the wire, or undefined when it is not one (an older acpmux, a bad answer).
export function readGlyph(raw: unknown): SignatureGlyph | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const glyph = raw as Record<string, unknown>;
  if (typeof glyph.accent !== "string" || !/^#[0-9a-fA-F]{6}$/.test(glyph.accent)) return undefined;
  if (!Array.isArray(glyph.dots)) return undefined;
  const dots: SignatureDot[] = [];
  for (const entry of glyph.dots) {
    const dot = entry as Record<string, unknown> | null;
    if (!dot || !unit(dot.x) || !unit(dot.y) || !unit(dot.r)) continue;
    dots.push({ x: dot.x, y: dot.y, r: dot.r, phase: unit(dot.phase) ? dot.phase : 0 });
  }
  if (dots.length === 0) return undefined;
  return {
    seed: unit(glyph.seed) ? glyph.seed : 0,
    variant: typeof glyph.variant === "string" ? glyph.variant : "",
    accent: glyph.accent,
    drift: unit(glyph.drift) ? glyph.drift : 1,
    dots,
  };
}

/// Glyphs by session id, and the asks in flight; `null` is an id acpmux gave no glyph for.
const glyphs = new Map<string, SignatureGlyph | null>();
const asking = new Map<string, Promise<SignatureGlyph | null>>();

function ask(source: AgentSignatureSource): Promise<SignatureGlyph | null> {
  const { sessionId } = source;
  const pending = asking.get(sessionId);
  if (pending) return pending;
  const request = source
    .fetch([sessionId])
    .then((result) => readGlyph((result as { signatures?: Record<string, unknown> } | null)?.signatures?.[sessionId]))
    .catch(() => undefined)
    .then((glyph) => {
      glyphs.set(sessionId, glyph ?? null);
      asking.delete(sessionId);
      return glyph ?? null;
    });
  asking.set(sessionId, request);
  return request;
}

/// The pane's glyph while the setting is on; nothing, and no request, while it is off.
export function useAgentSignature(): SignatureGlyph | undefined {
  const enabled = useAgentSignatureOn();
  const pane = useSyncExternalStore(subscribe, paneSnapshot, paneSnapshot);
  const source = useContext(AgentSignatureContext) ?? pane;
  const sessionId = enabled ? source?.sessionId : undefined;
  const [, redraw] = useState(0);
  useEffect(() => {
    if (!sessionId || !source || glyphs.has(sessionId)) return;
    let live = true;
    void ask(source).then(() => live && redraw((n) => n + 1));
    return () => {
      live = false;
    };
  }, [sessionId, source]);
  return sessionId ? (glyphs.get(sessionId) ?? undefined) : undefined;
}

/// Tests: forget every glyph and the setting.
export function resetAgentSignatures(): void {
  glyphs.clear();
  asking.clear();
  configureAgentSignature(false);
  paneSource = null;
}
