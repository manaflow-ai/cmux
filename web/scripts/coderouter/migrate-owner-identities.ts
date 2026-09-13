import { decryptCredential } from "../../services/coderouter/encryption";
import { needsCodexOwnerMigration, withCodexOwner } from "../../services/coderouter/codexIdentity";
import { bindCodexOwnerIdentity, listAccounts, listCoderouterTeamIds, listEncryptedCredentials } from "../../services/coderouter/repository";
import { closeCloudDbForTests } from "../../db/client";
import { Signer } from "@aws-sdk/rds-signer";
import { loadTargetEnv, projects } from "../cloud-vm/projects.mjs";

const targetIndex = process.argv.indexOf("--target");
if (targetIndex !== -1) {
  const target = process.argv[targetIndex + 1];
  if (target !== "staging" && target !== "production") throw new Error("--target must be staging or production");
  const env = loadTargetEnv(projects[target]);
  const signer = new Signer({ hostname: env.PGHOST, port: Number(env.PGPORT), username: env.PGUSER, region: env.AWS_REGION });
  const url = new URL(`postgres://${env.PGHOST}:${env.PGPORT}/${env.PGDATABASE}`);
  url.username = env.PGUSER;
  url.password = await signer.getAuthToken();
  url.searchParams.set("sslmode", "verify-full");
  process.env.CMUX_DB_DRIVER = "url";
  process.env.DATABASE_URL = url.href;
  process.env.AWS_REGION = env.AWS_REGION;
  delete process.env.DIRECT_DATABASE_URL;
  delete process.env.VERCEL;
}

// Metadata-only and resumable. This never refreshes or rewrites credentials.
const apply = process.argv.includes("--apply");
let scanned = 0;
let pending = 0;
let updated = 0;
let rejected = 0;
try {
  for (const teamId of await listCoderouterTeamIds()) {
    const accounts = await listAccounts(teamId);
    const byId = new Map(accounts.map(account => [account.id, account]));
    for (const envelope of await listEncryptedCredentials(teamId)) {
      if (envelope.provider !== "codex") continue;
      scanned++;
      try {
        const credential = await decryptCredential(envelope);
        if (credential.provider !== "codex") throw new Error("provider mismatch");
        const identified = withCodexOwner(credential);
        const account = byId.get(envelope.accountId);
        if (!account || account.providerAccountId !== credential.accountId) throw new Error("workspace mismatch");
        if (!needsCodexOwnerMigration(account, identified)) continue;
        pending++;
        if (!apply) continue;
        const changed = await bindCodexOwnerIdentity({ teamId, accountId: envelope.accountId, expectedKey: credential.accountId, expectedRevision: envelope.credentialRevision, credential: identified });
        if (!changed) throw new Error("record changed during migration");
        updated++;
      } catch {
        rejected++;
      }
    }
  }
  console.log(JSON.stringify({ apply, scanned, pending, updated, rejected }));
  if (rejected) process.exitCode = 1;
} finally {
  await closeCloudDbForTests();
}
