import {
  decryptCredential,
  encryptCredential,
} from "../../services/coderouter/encryption";
import {
  importEncryptedCredential,
  listCoderouterTeamIds,
  listEncryptedCredentials,
} from "../../services/coderouter/repository";
import { clearTeamVault, readTeamVault } from "../../services/coderouter/vault";
import { closeCloudDbForTests } from "../../db/client";

const deleteSource = process.argv.includes("--delete-source");
const verifyOnly = process.argv.includes("--verify-only");
if (deleteSource && verifyOnly) {
  throw new Error("--delete-source and --verify-only are mutually exclusive");
}
if (deleteSource && process.env.CODEROUTER_CONFIRM_DELETE_SOURCE !== "yes") {
  throw new Error(
    "CODEROUTER_CONFIRM_DELETE_SOURCE=yes is required with --delete-source",
  );
}

const teams = await listCoderouterTeamIds();
let migrated = 0;
let verified = 0;

for (const teamId of teams) {
  if (deleteSource) {
    const encrypted = await listEncryptedCredentials(teamId);
    for (const envelope of encrypted) {
      await decryptCredential(envelope);
      verified += 1;
    }
    const source = await readTeamVault(teamId);
    const encryptedIds = new Set(encrypted.map((value) => value.accountId));
    const missing = Object.keys(source.accounts)
      .filter((accountId) => !encryptedIds.has(accountId));
    if (missing.length > 0) {
      throw new Error(
        `refusing to delete source for team ${teamId}: ${missing.length} source accounts are not encrypted`,
      );
    }
    await clearTeamVault(teamId);
    continue;
  }

  if (!verifyOnly) {
    const source = await readTeamVault(teamId);
    for (const [accountId, account] of Object.entries(source.accounts)) {
      const encrypted = await encryptCredential({
        teamId,
        accountId,
        provider: account.credential.provider,
        credentialRevision: account.revision,
        credential: account.credential,
      });
      await importEncryptedCredential({
        credential: account.credential,
        encrypted,
      });
      migrated += 1;
    }
  }

  const encrypted = await listEncryptedCredentials(teamId);
  for (const envelope of encrypted) {
    await decryptCredential(envelope);
    verified += 1;
  }
}

console.log(JSON.stringify({
  teams: teams.length,
  migrated,
  verified,
  sourceDeleted: deleteSource,
}));
await closeCloudDbForTests();
