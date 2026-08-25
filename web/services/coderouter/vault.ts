import { getStackServerApp } from "../../app/lib/stack";
import type {
  CodeRouterCredential,
  CodeRouterVault,
  VaultAccount,
} from "./types";

const METADATA_KEY = "coderouterVaultV1";

export class CodeRouterVaultUnavailable extends Error {
  readonly _tag = "CodeRouterVaultUnavailable";
}

export class CodeRouterVaultCorrupt extends Error {
  readonly _tag = "CodeRouterVaultCorrupt";
}

export async function readTeamVault(teamId: string): Promise<CodeRouterVault> {
  const team = await getStackServerApp().getTeam(teamId);
  if (!team) throw new CodeRouterVaultUnavailable("coderouter team not found");
  return parseVault(team.serverMetadata?.[METADATA_KEY]);
}

export async function writeTeamVault(
  teamId: string,
  vault: CodeRouterVault,
): Promise<void> {
  const team = await getStackServerApp().getTeam(teamId);
  if (!team) throw new CodeRouterVaultUnavailable("coderouter team not found");
  const metadata = isRecord(team.serverMetadata)
    ? { ...team.serverMetadata }
    : {};
  await team.update({
    serverMetadata: {
      ...metadata,
      [METADATA_KEY]: vault,
    },
  });
}

export async function clearTeamVault(teamId: string): Promise<void> {
  const team = await getStackServerApp().getTeam(teamId);
  if (!team) throw new CodeRouterVaultUnavailable("coderouter team not found");
  const metadata = isRecord(team.serverMetadata)
    ? { ...team.serverMetadata }
    : {};
  delete metadata[METADATA_KEY];
  await team.update({ serverMetadata: metadata });
}

export async function putVaultCredential(
  teamId: string,
  accountId: string,
  credential: CodeRouterCredential,
  expectedRevision?: number,
): Promise<number> {
  const vault = await readTeamVault(teamId);
  const current = vault.accounts[accountId];
  if (
    expectedRevision !== undefined &&
    current?.revision !== expectedRevision
  ) {
    throw new CodeRouterVaultUnavailable("vault revision changed");
  }
  const revision = (current?.revision ?? 0) + 1;
  await writeTeamVault(teamId, {
    version: 1,
    accounts: {
      ...vault.accounts,
      [accountId]: { revision, credential },
    },
  });
  return revision;
}

export async function deleteVaultCredential(
  teamId: string,
  accountId: string,
): Promise<void> {
  const vault = await readTeamVault(teamId);
  if (!(accountId in vault.accounts)) return;
  const accounts = { ...vault.accounts };
  delete accounts[accountId];
  await writeTeamVault(teamId, { version: 1, accounts });
}

export function parseVault(value: unknown): CodeRouterVault {
  if (value === undefined || value === null) {
    return { version: 1, accounts: {} };
  }
  if (!isRecord(value) || value.version !== 1 || !isRecord(value.accounts)) {
    throw new CodeRouterVaultCorrupt("invalid coderouter vault");
  }
  const accounts: Record<string, VaultAccount> = {};
  for (const [accountId, candidate] of Object.entries(value.accounts)) {
    if (
      !isRecord(candidate) ||
      !Number.isSafeInteger(candidate.revision) ||
      (candidate.revision as number) < 1 ||
      !isCredential(candidate.credential)
    ) {
      throw new CodeRouterVaultCorrupt("invalid coderouter vault account");
    }
    accounts[accountId] = {
      revision: candidate.revision as number,
      credential: candidate.credential,
    };
  }
  return { version: 1, accounts };
}

function isCredential(value: unknown): value is CodeRouterCredential {
  if (!isRecord(value)) return false;
  const common =
    nonEmptyString(value.accessToken) &&
    nonEmptyString(value.refreshToken) &&
    nonEmptyString(value.accountId) &&
    nonEmptyString(value.email) &&
    typeof value.expiresAt === "number";
  if (!common) return false;
  if (value.provider === "codex") return nonEmptyString(value.idToken);
  return value.provider === "opencode-go" &&
    (value.orgId === undefined || typeof value.orgId === "string") &&
    (value.orgName === undefined || typeof value.orgName === "string");
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function isRecord(value: unknown): value is Record<string, any> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
