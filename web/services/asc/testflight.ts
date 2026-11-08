import {
  AscApiError,
  ascFetch,
} from "./client";
import {
  FOUNDER_TESTFLIGHT_GROUP_ID,
  metadataAfterProTestflightRemoval,
  proOwnedLegacyTestflightEmails,
  proTestflightEnrollmentEmails,
  proTestflightGrants,
  proTestflightRemovalTargets,
} from "./testflightOwnership";
import { env } from "../../app/env";

export {
  FOUNDER_TESTFLIGHT_GROUP_ID,
  proOwnedLegacyTestflightEmails,
  proOwnedLegacyTestflightGroupIDs,
  proTestflightEnrollmentEmails,
  proTestflightGrants,
  proTestflightRemovalTargets,
  recordProOwnedLegacyTestflightGroup,
  recordProTestflightEnrollmentEmail,
  type ProTestflightRemovalTarget,
  type ProTestflightGrant,
  type ProTestflightOwnershipUser,
} from "./testflightOwnership";

export const PRO_TESTFLIGHT_GROUP_ID =
  env.CMUX_PRO_TESTFLIGHT_GROUP_ID ||
  "34fbede5-3880-4560-b1bb-a45787249780";

export type RemoveTesterOptions = {
  /**
   * Server-recorded legacy group memberships that were created by Pro. Never
   * infer these from current ASC overlap because genuine Founders can also
   * subscribe to Pro.
   */
  readonly ownedLegacyGroupIDs?: readonly string[];
};

type JsonApiResource = {
  readonly id: string;
  readonly type: string;
  readonly attributes?: Record<string, unknown>;
};

type JsonApiList = {
  readonly data?: readonly JsonApiResource[];
};

type JsonApiDocument = {
  readonly data?: JsonApiResource;
};

export type TestFlightGroupStatus = {
  readonly enrolled: boolean;
  readonly state?: string;
};

export async function findBetaTesterByEmail(
  email: string,
): Promise<{ id: string; state?: string } | null> {
  const response = await ascFetch<JsonApiList>(
    `/v1/betaTesters?filter[email]=${encodeURIComponent(normalizeEmail(email))}&limit=1`,
  );
  const tester = response.data?.[0];
  return tester ? { id: tester.id, state: testerState(tester) } : null;
}

export async function testerGroupStatus(
  email: string,
): Promise<TestFlightGroupStatus> {
  const tester = await findBetaTesterByEmail(email);
  if (!tester) return { enrolled: false };

  const enrolled = await testerIsInProGroup(tester.id);
  return {
    enrolled,
    state: tester.state,
  };
}

async function testerIsInProGroup(testerId: string): Promise<boolean> {
  return (await testerGroupIDs(testerId)).has(PRO_TESTFLIGHT_GROUP_ID);
}

async function testerGroupIDs(testerId: string): Promise<Set<string>> {
  const response = await ascFetch<JsonApiList>(
    `/v1/betaTesters/${encodeURIComponent(testerId)}/betaGroups?limit=200`,
  );
  return new Set(response.data?.map((group) => group.id) ?? []);
}

export async function enrollTester(
  email: string,
  firstName?: string,
  lastName?: string,
): Promise<void> {
  // TestFlight automatically emails testers added to a build or beta group.
  // betaTesterInvitations is the explicit resend path and must not run here.
  const normalizedEmail = normalizeEmail(email);
  try {
    const response = await ascFetch<JsonApiDocument>("/v1/betaTesters", {
      method: "POST",
      body: JSON.stringify({
        data: {
          type: "betaTesters",
          attributes: {
            email: normalizedEmail,
            firstName: optionalString(firstName),
            lastName: optionalString(lastName),
          },
          relationships: {
            betaGroups: {
              data: [{ type: "betaGroups", id: PRO_TESTFLIGHT_GROUP_ID }],
            },
          },
        },
      }),
    });
    if (!response.data?.id) {
      throw new AscApiError("Created beta tester response did not include an id", 502);
    }
    return;
  } catch (error) {
    if (!isAlreadyExistsError(error)) throw error;
  }

  const tester = await findBetaTesterByEmail(normalizedEmail);
  if (!tester) throw new AscApiError("Existing beta tester could not be found", 409);
  if (!(await testerIsInProGroup(tester.id))) {
    await addTesterToGroup(tester.id);
  }
}

export async function removeTester(
  email: string,
  options: RemoveTesterOptions = {},
): Promise<void> {
  const tester = await findBetaTesterByEmail(email);
  if (!tester) return;
  const groupIDs = [
    PRO_TESTFLIGHT_GROUP_ID,
    ...(options.ownedLegacyGroupIDs ?? []).filter(
      (groupID) => groupID === FOUNDER_TESTFLIGHT_GROUP_ID,
    ),
  ];
  for (const groupID of new Set(groupIDs)) {
    await removeTesterFromGroup(tester.id, groupID);
  }
}

export async function removeProTesterAccess(
  currentEmail: string | null | undefined,
  metadata: unknown,
  remover: typeof removeTester = removeTester,
  options: {
    readonly beforeExternalMutation?: () => void | Promise<void>;
    readonly updateMetadata?: (metadata: unknown) => Promise<unknown>;
  } = {},
): Promise<number> {
  const targets = proTestflightRemovalTargets(currentEmail, metadata);
  const recordedEmails = new Set([
    ...proTestflightEnrollmentEmails(metadata),
    ...proTestflightGrants(metadata).map((grant) => grant.email),
    ...proOwnedLegacyTestflightEmails(metadata),
  ]);
  let workingMetadata = metadata;
  for (const target of targets) {
    await options.beforeExternalMutation?.();
    await remover(target.email, {
      ownedLegacyGroupIDs: target.ownedLegacyGroupIDs,
    });
    if (recordedEmails.delete(target.email) && options.updateMetadata) {
      workingMetadata = metadataAfterProTestflightRemoval(
        workingMetadata,
        target.email,
      );
      await options.updateMetadata(workingMetadata);
    }
  }
  return targets.length;
}

async function removeTesterFromGroup(
  testerId: string,
  groupID: string,
): Promise<void> {
  try {
    await ascFetch(`/v1/betaGroups/${encodeURIComponent(groupID)}/relationships/betaTesters`, {
      method: "DELETE",
      body: JSON.stringify({
        data: [{ type: "betaTesters", id: testerId }],
      }),
    });
  } catch (error) {
    if (isMissingRelationshipError(error)) return;
    throw error;
  }
}

async function addTesterToGroup(testerId: string): Promise<void> {
  try {
    await ascFetch(`/v1/betaGroups/${encodeURIComponent(PRO_TESTFLIGHT_GROUP_ID)}/relationships/betaTesters`, {
      method: "POST",
      body: JSON.stringify({
        data: [{ type: "betaTesters", id: testerId }],
      }),
    });
  } catch (error) {
    if (isAlreadyExistsError(error)) return;
    throw error;
  }
}

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

function optionalString(value: string | undefined): string | undefined {
  const normalized = value?.trim();
  return normalized ? normalized : undefined;
}

function testerState(tester: JsonApiResource): string | undefined {
  const attributes = tester.attributes;
  const state =
    attributes?.state ??
    attributes?.betaTesterState ??
    attributes?.inviteType;
  return typeof state === "string" && state.trim() ? state.trim() : undefined;
}

function isAlreadyExistsError(error: unknown): boolean {
  if (!(error instanceof AscApiError)) return false;
  if (error.status === 409) return true;
  return JSON.stringify(error.details ?? "").toLowerCase().includes("already");
}

function isMissingRelationshipError(error: unknown): boolean {
  return error instanceof AscApiError && (error.status === 404 || error.status === 409);
}
