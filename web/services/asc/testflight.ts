import {
  AscApiError,
  ascFetch,
} from "./client";
import { env } from "../../app/env";

export const TESTFLIGHT_APP_ID =
  env.CMUX_TESTFLIGHT_APP_ID || "6757092429";
export const PRO_TESTFLIGHT_GROUP_ID =
  env.CMUX_PRO_TESTFLIGHT_GROUP_ID ||
  "34fbede5-3880-4560-b1bb-a45787249780";

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
  const response = await ascFetch<JsonApiList>(
    `/v1/betaTesters/${encodeURIComponent(testerId)}/betaGroups?limit=200`,
  );
  return Boolean(
    response.data?.some((group) => group.id === PRO_TESTFLIGHT_GROUP_ID),
  );
}

export async function enrollTester(
  email: string,
  firstName?: string,
  lastName?: string,
): Promise<void> {
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
    const testerId = response.data?.id;
    if (!testerId) {
      throw new AscApiError("Created beta tester response did not include an id", 502);
    }
    await sendTesterInvitation(testerId);
    return;
  } catch (error) {
    if (!isAlreadyExistsError(error)) throw error;
  }

  const tester = await findBetaTesterByEmail(normalizedEmail);
  if (!tester) throw new AscApiError("Existing beta tester could not be found", 409);
  if (await testerIsInProGroup(tester.id)) return;
  const added = await addTesterToGroup(tester.id);
  if (added) await sendTesterInvitation(tester.id);
}

export async function removeTester(email: string): Promise<void> {
  const tester = await findBetaTesterByEmail(email);
  if (!tester) return;
  try {
    await ascFetch(`/v1/betaGroups/${encodeURIComponent(PRO_TESTFLIGHT_GROUP_ID)}/relationships/betaTesters`, {
      method: "DELETE",
      body: JSON.stringify({
        data: [{ type: "betaTesters", id: tester.id }],
      }),
    });
  } catch (error) {
    if (isMissingRelationshipError(error)) return;
    throw error;
  }
}

async function addTesterToGroup(testerId: string): Promise<boolean> {
  try {
    await ascFetch(`/v1/betaGroups/${encodeURIComponent(PRO_TESTFLIGHT_GROUP_ID)}/relationships/betaTesters`, {
      method: "POST",
      body: JSON.stringify({
        data: [{ type: "betaTesters", id: testerId }],
      }),
    });
    return true;
  } catch (error) {
    if (isAlreadyExistsError(error)) return false;
    throw error;
  }
}

async function sendTesterInvitation(testerId: string): Promise<void> {
  try {
    await ascFetch("/v1/betaTesterInvitations", {
      method: "POST",
      body: JSON.stringify({
        data: {
          type: "betaTesterInvitations",
          relationships: {
            app: {
              data: { type: "apps", id: TESTFLIGHT_APP_ID },
            },
            betaTester: {
              data: { type: "betaTesters", id: testerId },
            },
          },
        },
      }),
    });
  } catch (error) {
    // A concurrent request or Stripe retry may have sent this exact invite.
    // Group membership is the durable access boundary, so an existing invite
    // is idempotent success.
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
