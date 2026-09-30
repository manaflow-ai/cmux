import { ORPCError } from "@orpc/client";
import { dashboardRefusal } from "./refusal";

/** The sentence a failed data region shows, one per class of failure. */
export type RefusalMessageKind = "network" | "unavailable" | "forbidden" | "notFound" | "rateLimited" | "generic";

/**
 * Classify a load failure for `SectionError`. Declared refusals map by
 * status; an undeclared server error reads as unavailable; a fetch that
 * never got a response (offline, DNS, timeout) reads as network.
 */
export function refusalMessageKind(error: unknown): RefusalMessageKind {
  const refusal = dashboardRefusal(error);
  const status = refusal?.status ?? (error instanceof ORPCError ? error.status : undefined);
  if (status !== undefined) return kindForStatus(status);
  if (error instanceof TypeError) return "network";
  if (error instanceof DOMException && (error.name === "TimeoutError" || error.name === "NetworkError")) return "network";
  return "generic";
}

function kindForStatus(status: number): RefusalMessageKind {
  if (status === 403) return "forbidden";
  if (status === 404 || status === 410) return "notFound";
  if (status === 429) return "rateLimited";
  if (status >= 500) return "unavailable";
  return "generic";
}
