import { getStackServerApp } from "../../app/lib/stack";
import { Cause, Effect } from "effect";

export type VmTeamDirectory = {
  listMemberIds(teamId: string, options?: { signal?: AbortSignal }): Promise<readonly string[] | null>;
};

export function vmTeamDirectory(): VmTeamDirectory {
  return {
    async listMemberIds(teamId, options) {
      if (options?.signal?.aborted) throw new DOMException("aborted", "AbortError");
      const team = await getStackServerApp().getTeam(teamId);
      if (!team) return null;
      // The Stack SDK does not accept AbortSignal, so only the preflight can be cancelled.
      if (options?.signal?.aborted) throw new DOMException("aborted", "AbortError");
      return (await team.listUsers()).map((user) => user.id);
    },
  };
}

export function vmClientRoutesTeamNetworks(request: Request): boolean {
  return request.headers.get("x-cmux-private-network-routing")
    ?.split(",")
    .map((token) => token.trim())
    .includes("team-networks") ?? false;
}

export type VmTeamMemberLookup =
  | { readonly memberIds: readonly string[] | null }
  | { readonly error: "timeout" | "error" };

/** Performs a bounded, cancellation-aware team member lookup. */
export function listTeamMemberIdsWithTimeout(
  directory: VmTeamDirectory,
  teamId: string,
  timeoutMs = 3000,
): Effect.Effect<VmTeamMemberLookup, never> {
  return Effect.tryPromise({
    try: (signal) => directory.listMemberIds(teamId, { signal }),
    catch: (error) => error,
  }).pipe(
    Effect.timeout(timeoutMs),
    Effect.map((memberIds) => ({ memberIds })),
    Effect.catchAll((error) => Effect.succeed({
      error: Cause.isTimeoutException(error)
        ? "timeout" as const : "error" as const,
    })),
  );
}
