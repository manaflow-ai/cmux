import {
  AscApiError,
  ascFetch,
} from "./client";
import { env } from "../../app/env";

export const TESTFLIGHT_APP_ID =
  env.CMUX_TESTFLIGHT_APP_ID || "6757092429";
export const TESTFLIGHT_GROUP_ID =
  env.CMUX_TESTFLIGHT_GROUP_ID ||
  "3ee84bfa-10ad-4f23-a45c-f9a3b037373e";

type JsonApiResource = {
  readonly id: string;
  readonly type: string;
  readonly attributes?: Record<string, unknown>;
};

type JsonApiList = {
  readonly data?: readonly JsonApiResource[];
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

  const response = await ascFetch<JsonApiList>(
    `/v1/betaTesters/${encodeURIComponent(tester.id)}/betaGroups?limit=200`,
  );
  const enrolled = Boolean(
    response.data?.some((group) => group.id === TESTFLIGHT_GROUP_ID),
  );
  return {
    enrolled,
    state: tester.state,
  };
}

export async function enrollTester(
  email: string,
  firstName?: string,
  lastName?: string,
): Promise<void> {
  const normalizedEmail = normalizeEmail(email);
  try {
    await ascFetch("/v1/betaTesters", {
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
              data: [{ type: "betaGroups", id: TESTFLIGHT_GROUP_ID }],
            },
          },
        },
      }),
    });
    return;
  } catch (error) {
    if (!isAlreadyExistsError(error)) throw error;
  }

  const tester = await findBetaTesterByEmail(normalizedEmail);
  if (!tester) throw new AscApiError("Existing beta tester could not be found", 409);
  await addTesterToGroup(tester.id);
}

export async function removeTester(email: string): Promise<void> {
  const tester = await findBetaTesterByEmail(email);
  if (!tester) return;
  try {
    await ascFetch(`/v1/betaGroups/${encodeURIComponent(TESTFLIGHT_GROUP_ID)}/relationships/betaTesters`, {
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

async function addTesterToGroup(testerId: string): Promise<void> {
  try {
    await ascFetch(`/v1/betaGroups/${encodeURIComponent(TESTFLIGHT_GROUP_ID)}/relationships/betaTesters`, {
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
