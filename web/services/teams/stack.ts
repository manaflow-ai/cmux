import { Effect } from "effect";
import { getStackServerApp } from "../../app/lib/stack";
import { TeamGoneError, TeamServiceUnavailableError } from "./errors";

/**
 * The subset of the Stack server SDK the team services use. Method syntax
 * keeps parameters bivariant, so the real `StackServerApp` satisfies it and
 * tests can pass small fakes without mocking modules.
 */
export type StackTeamMember = {
  readonly id: string;
  readonly displayName?: string | null;
  readonly primaryEmail?: string | null;
  readonly profileImageUrl?: string | null;
  readonly teamProfile?: {
    readonly displayName: string | null;
    readonly profileImageUrl: string | null;
  };
};

export type StackSentInvitation = {
  readonly id: string;
  readonly recipientEmail: string | null;
  readonly expiresAt: Date;
  revoke(): Promise<void>;
};

export type StackTeam = {
  readonly id: string;
  readonly displayName: string;
  readonly profileImageUrl: string | null;
  readonly clientReadOnlyMetadata?: unknown;
  listUsers(): Promise<readonly StackTeamMember[]>;
  addUser(userId: string): Promise<void>;
  removeUser(userId: string): Promise<void>;
  inviteUser(options: { email: string; callbackUrl?: string }): Promise<void>;
  listInvitations(): Promise<readonly StackSentInvitation[]>;
  update(update: { displayName?: string; profileImageUrl?: string | null }): Promise<void>;
  delete(): Promise<void>;
};

export type StackContactChannel = {
  readonly type: string;
  readonly value: string;
  readonly isVerified: boolean;
};

export type StackUser = {
  readonly id: string;
  readonly primaryEmail: string | null;
  readonly primaryEmailVerified: boolean;
  // Stack reads only `scope.id`; the narrow type lets the SDK's `Team` fit.
  grantPermission(scope: { readonly id: string }, permissionId: string): Promise<void>;
  revokePermission(scope: { readonly id: string }, permissionId: string): Promise<void>;
  update(update: { selectedTeamId?: string | null }): Promise<void>;
  listContactChannels(): Promise<readonly StackContactChannel[]>;
};

export type StackTokenStore =
  | { readonly accessToken: string; readonly refreshToken: string }
  | { readonly headers: { get(name: string): string | null } };

export type TeamStackApp = {
  getTeam(teamId: string): Promise<StackTeam | null>;
  getUser(userId: string): Promise<StackUser | null>;
  createTeam(options: { displayName: string; creatorUserId?: string }): Promise<StackTeam>;
  listTeamMemberPermissions(
    teamId: string,
    options?: { recursive?: boolean },
  ): Promise<readonly { readonly userId: string; readonly permissionId: string }[]>;
  getAuthJson(options: { tokenStore: StackTokenStore }): Promise<{ accessToken: string | null }>;
};

/** Adapt the SDK app; the adapter picks `getUser`'s by-id overload explicitly. */
export function defaultTeamStackApp(): TeamStackApp {
  const app = getStackServerApp();
  return {
    getTeam: (teamId) => app.getTeam(teamId),
    getUser: (userId) => app.getUser(userId),
    createTeam: (options) => app.createTeam(options),
    listTeamMemberPermissions: (teamId, options) => app.listTeamMemberPermissions(teamId, options),
    getAuthJson: (options) => app.getAuthJson(options),
  };
}

const STACK_TIMEOUT = "10 seconds";

/**
 * Run a Stack call under a deadline. The SDK has no AbortSignal, so a hung
 * call is abandoned, and every failure becomes a retryable unavailability:
 * callers never read a Stack error as a permission answer.
 */
export async function withStackDeadline<T>(operation: () => Promise<T>): Promise<T> {
  const result = await Effect.runPromise(
    Effect.tryPromise(operation).pipe(Effect.timeout(STACK_TIMEOUT), Effect.either),
  );
  if (result._tag === "Left") {
    // A deleted team is an answer, not an outage: retrying cannot succeed.
    if (isTeamNotFound(unwrapEffectCause(result.left))) throw new TeamGoneError("Stack team not found");
    const failure = result.left;
    const cause = failure && typeof failure === "object" && "error" in failure ? (failure as { error: unknown }).error : failure;
    // Only the error class and a bounded message: enough to tell a Stack
    // refusal (untrusted callback domain, disabled emails) from a timeout.
    console.error("stack team request failed", {
      errorType: cause instanceof Error ? cause.name : typeof cause,
      message: cause instanceof Error ? cause.message.slice(0, 300) : String(cause).slice(0, 300),
    });
    throw new TeamServiceUnavailableError("Stack team request failed");
  }
  return result.right;
}

/** `Effect.tryPromise` wraps a rejection as `UnknownException { error }`. */
function unwrapEffectCause(failure: unknown): unknown {
  return failure && typeof failure === "object" && "error" in failure
    ? (failure as { error: unknown }).error
    : failure;
}

/** Stack's known error for a team that does not exist (or was just deleted). */
export function isTeamNotFound(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const candidate = error as { errorCode?: unknown; code?: unknown };
  return candidate.errorCode === "TEAM_NOT_FOUND" || candidate.code === "TEAM_NOT_FOUND";
}

/** Stack team ids are UUIDs; anything else cannot name a team. */
export function isStackTeamId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(value);
}

/** Stack reports an existing membership as a known error; that is success. */
export function isTeamMembershipAlreadyExists(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const candidate = error as { errorCode?: unknown; code?: unknown };
  return candidate.errorCode === "TEAM_MEMBERSHIP_ALREADY_EXISTS" ||
    candidate.code === "TEAM_MEMBERSHIP_ALREADY_EXISTS";
}
