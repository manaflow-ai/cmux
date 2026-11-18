/// Auto, where a new chat starts (design/auto-chat-placement.md; Leo, 2026-11-18: "an auto mode as an
/// umbrella over remote/local/cloud itself. so it just goes. thats essentialyl what we're doing rn with
/// teh lanes going to various machines"). The page decides nothing: on the first send it asks acpmux
/// (`_acpmux/place_chat`, acpmux chat_place.rs), which weighs this Mac, each joined machine and Cloud,
/// and the page starts the chat where the verdict says. An acpmux that predates the request, or one
/// that fails it, leaves the chat on This Mac, and the picker says so.
import type { RunMode } from "./sandboxRun";

/// Where acpmux put the chat: This Mac, a joined machine (`peer`), or Cloud. `why` is acpmux's one line
/// for it ("This Mac: room for 6"); `overloaded` says no place had room and This Mac takes it anyway.
export type AutoVerdict =
  | { place: "local"; why: string; overloaded: boolean }
  | { place: "peer"; peer: string; why: string; overloaded: boolean }
  | { place: "cloud"; why: string; overloaded: boolean };

/// The request's params, as the app knows them. `cloud.available`: signed in to Cloud with a plan
/// that lets a send start (cloudPlans.ts `cloudPlanHoldsSend`), and Cloud offered for this chat. The
/// folder is `cwd` only: acpmux measures it itself (the pane relay refuses any `folder` key, which it
/// reads as a path).
export type PlaceChatParams = {
  cwd?: string;
  cloud: { available: boolean };
};

export function placeChatParams(cwd: string | undefined, cloudAvailable: boolean): PlaceChatParams {
  return { ...(cwd && cwd.startsWith("/") ? { cwd } : {}), cloud: { available: cloudAvailable } };
}

/// The verdict in acpmux's answer, or undefined when it names no place this page can start a chat in.
export function readAutoVerdict(value: unknown): AutoVerdict | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as { place?: unknown; peer?: unknown; why?: unknown; overloaded?: unknown };
  const why = typeof raw.why === "string" ? raw.why : "";
  const overloaded = raw.overloaded === true;
  if (raw.place === "local" || raw.place === "cloud") return { place: raw.place, why, overloaded };
  if (raw.place === "peer" && typeof raw.peer === "string" && raw.peer)
    return { place: "peer", peer: raw.peer, why, overloaded };
  return undefined;
}

/// What the picker says once Auto placed the chat: the place's name after "Auto · ", and acpmux's
/// reason as its tooltip. `fallback`: acpmux could not be asked, so the chat started on This Mac.
export type AutoPlaced = { place: "local" | "peer" | "cloud"; peer?: string; why?: string; fallback?: true };

export function autoPlaced(verdict: AutoVerdict | undefined): AutoPlaced {
  if (!verdict) return { place: "local", fallback: true };
  return {
    place: verdict.place,
    ...(verdict.place === "peer" ? { peer: verdict.peer } : {}),
    ...(verdict.why ? { why: verdict.why } : {}),
  };
}

/// The run mode a verdict starts the chat in: Cloud's start for Cloud, else a chat (This Mac or the
/// machine the verdict names).
export function autoRunMode(placed: AutoPlaced): RunMode {
  return placed.place === "cloud" ? "cloud" : "persistent";
}

/// The place's name for "Auto · <place>": This Mac, the machine's name, or Cloud.
export function autoPlaceName(placed: AutoPlaced, names: { thisMac: string; cloud: string }): string {
  return placed.place === "cloud" ? names.cloud : placed.place === "peer" && placed.peer ? placed.peer : names.thisMac;
}

/// How long a send waits for acpmux's verdict before it starts on This Mac: the folder walk is bounded
/// on acpmux's side, and the person's prompt never waits longer than this for a place.
export const AUTO_PLACE_DEADLINE_MS = 5_000;
