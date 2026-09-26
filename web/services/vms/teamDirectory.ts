import { getStackServerApp } from "../../app/lib/stack";

export type VmTeamDirectory = {
  listMemberIds(teamId: string): Promise<readonly string[] | null>;
};

export function vmTeamDirectory(): VmTeamDirectory {
  return {
    async listMemberIds(teamId) {
      const team = await getStackServerApp().getTeam(teamId);
      if (!team) return null;
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

export function listTeamMemberIdsWithTimeout(
  directory: VmTeamDirectory,
  teamId: string,
  timeoutMs = 3000,
): Promise<VmTeamMemberLookup> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<VmTeamMemberLookup>((resolve) => {
    timer = setTimeout(() => resolve({ error: "timeout" }), timeoutMs);
  });
  const lookup = Promise.resolve().then(() => directory.listMemberIds(teamId))
    .then((memberIds) => ({ memberIds }) satisfies VmTeamMemberLookup)
    .catch(() => ({ error: "error" as const } satisfies VmTeamMemberLookup));
  return Promise.race([lookup, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}
