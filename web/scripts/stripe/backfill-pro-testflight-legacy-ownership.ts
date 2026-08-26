import { StackServerApp } from "@stackframe/stack";

import { cloudDb } from "../../db/client";
import {
  type AccountMetadataUserLoader,
  withFreshAccountMetadataUser,
} from
  "../../services/account/metadataMutation";
import {
  proOwnedLegacyTestflightEmails,
  proOwnedLegacyTestflightGroupIDs,
  recordProOwnedLegacyTestflightGroup,
  type ProTestflightOwnershipUser,
} from "../../services/asc/testflightOwnership";

const CUTOVER_AT = "2026-07-24T09:13:32.106Z";

type ManifestEntry = {
  readonly stackUserId: string;
  readonly email: string;
};

type Manifest = {
  readonly cutoverAt: string;
  readonly users: readonly ManifestEntry[];
};

const apply = process.argv.slice(2).includes("--apply");
const unknownArguments = process.argv.slice(2).filter((argument) => argument !== "--apply");
if (unknownArguments.length > 0) {
  throw new Error(`Unknown argument: ${unknownArguments[0]}`);
}

const manifest = parseManifest(await readStdin());
const projectId = requiredEnv("NEXT_PUBLIC_STACK_PROJECT_ID");
const publishableClientKey = requiredEnv("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY");
const secretServerKey = requiredEnv("STACK_SECRET_SERVER_KEY");
const stack = new StackServerApp({
  projectId,
  publishableClientKey,
  secretServerKey,
  tokenStore: null,
  noAutomaticPrefetch: true,
});
type BackfillStackUser = ProTestflightOwnershipUser & { readonly id: string };
const stackUserLoader: AccountMetadataUserLoader<BackfillStackUser> = {
  getUser: (userId) => stack.getUser(userId),
};
const db = apply ? cloudDb() : null;

const candidates: {
  stackUserId: string;
  user: ProTestflightOwnershipUser;
  email: string;
}[] = [];
for (const entry of manifest.users) {
  const user = await stack.getUser(entry.stackUserId);
  if (!user) throw new Error("Backfill manifest references a missing Stack user");
  candidates.push({ stackUserId: entry.stackUserId, user, email: entry.email });
}

let alreadyRecorded = 0;
let updated = 0;
for (const { stackUserId, user, email } of candidates) {
  if (apply && db) {
    const changed = await withFreshAccountMetadataUser({
      db,
      userId: stackUserId,
      loader: stackUserLoader,
      operation: (freshUser, lease) =>
        recordProOwnedLegacyTestflightGroup(freshUser, email, lease),
    });
    if (changed) updated += 1;
    else alreadyRecorded += 1;
    continue;
  }

  const metadata = user.clientReadOnlyMetadata;
  const hasGroup = proOwnedLegacyTestflightGroupIDs(metadata).length > 0;
  const hasEmail = proOwnedLegacyTestflightEmails(metadata).includes(email);
  if (hasGroup && hasEmail) alreadyRecorded += 1;
}

console.log(JSON.stringify({
  mode: apply ? "apply" : "dry-run",
  auditedUsers: candidates.length,
  alreadyRecorded,
  wouldUpdate: apply ? 0 : candidates.length - alreadyRecorded,
  updated,
}, null, 2));

function parseManifest(raw: string): Manifest {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("Backfill manifest must be valid JSON on stdin");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Backfill manifest must be an object");
  }
  const manifest = parsed as { cutoverAt?: unknown; users?: unknown };
  if (manifest.cutoverAt !== CUTOVER_AT) {
    throw new Error(`Backfill manifest cutoverAt must be ${CUTOVER_AT}`);
  }
  if (!Array.isArray(manifest.users) || manifest.users.length === 0) {
    throw new Error("Backfill manifest users must be a non-empty array");
  }

  const seenUserIDs = new Set<string>();
  const users = manifest.users.map((value): ManifestEntry => {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("Backfill manifest user must be an object");
    }
    const entry = value as { stackUserId?: unknown; email?: unknown };
    const stackUserId = nonEmptyString(entry.stackUserId);
    const email = normalizeEmail(entry.email);
    if (!stackUserId || !email) {
      throw new Error("Backfill manifest users require stackUserId and email");
    }
    if (seenUserIDs.has(stackUserId)) {
      throw new Error("Backfill manifest contains a duplicate Stack user");
    }
    seenUserIDs.add(stackUserId);
    return { stackUserId, email };
  });
  return { cutoverAt: CUTOVER_AT, users };
}

function requiredEnv(key: string): string {
  const value = process.env[key]?.trim();
  if (!value) throw new Error(`${key} is required`);
  return value;
}

async function readStdin(): Promise<string> {
  process.stdin.setEncoding("utf8");
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  return input;
}

function nonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return value.trim() || null;
}

function normalizeEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return normalized && normalized.includes("@") ? normalized : null;
}
