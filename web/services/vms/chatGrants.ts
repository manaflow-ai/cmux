// Sharing app-started chats on a team Cloud machine (Leo, 2026-10-31: "we
// can't simply block always. we need to be able to get shit running asap").
//
// cmux-tui on a Cloud machine starts an app chat only for an `owner` caller
// (attach-endpoint's `vmKind`, vmKindForCaller). A machine's creator is
// `owner` while they stay on its team; a grant here makes one more teammate
// `owner` for that machine, until it is taken back. The rules mirror
// cmux-platform's machineAccess (src/server/machines/Access.ts):
//
// - start_chat: the creator, or a current member of the machine's team who
//   holds a grant. Never on a personal-account machine (only its creator can
//   reach it).
// - share_chat (grant and revoke): the creator while still a member, or a
//   team admin.
//
// Every Stack read is bounded and fails closed: an unread member list or
// admin bit refuses the change (503) and never widens access.
import * as Effect from "effect/Effect";
import { getStackServerApp } from "../../app/lib/stack";
import { resolveTeamBillingAccess } from "../billing/teamBillingAccess";
import { VmRepository, type CloudVmChatGrantRow, type CloudVmRow } from "./repository";
import { listTeamMemberIdsWithTimeout, type VmTeamDirectory } from "./teamDirectory";
import { vmAcceptsChatGrants } from "./vmKind";
import { requireUserVm } from "./workflows";

/** How long one Stack read (members, or the caller's admin bit) may take. */
const STACK_READ_TIMEOUT_MS = 3000;
/** Stack user ids are short; anything longer is not one. */
const MAX_USER_ID_LENGTH = 200;

export type VmChatGrantRefusal = {
  readonly status: 400 | 403 | 409 | 503;
  readonly error: string;
  readonly message: string;
};

export type VmChatGrantOutcome<A> =
  | { readonly ok: true; readonly value: A }
  | { readonly ok: false; readonly refusal: VmChatGrantRefusal };

/** Whether `userId` holds Stack `team_admin` on `teamId`. Throws when it cannot tell. */
export type VmTeamAdminCheck = (teamId: string, userId: string) => Promise<boolean>;

export type VmChatGrantAccessInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
};

export type VmChatGrantShareInput = VmChatGrantAccessInput & {
  readonly teamDirectory: VmTeamDirectory;
  readonly isTeamAdmin: VmTeamAdminCheck;
  /** The teammate the grant is for. */
  readonly targetUserId: string;
};

export type VmChatGrantView = {
  readonly userId: string;
  readonly grantedBy: string;
  readonly createdAt: string;
};

export function vmChatGrantView(row: CloudVmChatGrantRow): VmChatGrantView {
  return { userId: row.userId, grantedBy: row.grantedBy, createdAt: row.createdAt.toISOString() };
}

const refuse = (status: VmChatGrantRefusal["status"], error: string, message: string) =>
  ({ ok: false as const, refusal: { status, error, message } });

const unavailable = () => refuse(503, "vm_chat_grants_unavailable", "Machine sharing is unavailable right now. Try again in a moment.");
const forbidden = () => refuse(403, "vm_chat_share_forbidden", "Only the machine's creator or a team admin can share chats on it.");
const personalMachine = () => refuse(409, "vm_chat_grants_personal_machine", "This machine is on a personal account, so only its creator can start chats on it.");

/** Who may start chats on the machine besides its creator. Anyone who can reach the machine may read it. */
export function listVmChatGrants(input: VmChatGrantAccessInput) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* requireUserVm(input);
    if (!vmAcceptsChatGrants(vm)) return { ok: true as const, value: [] as VmChatGrantView[] };
    if (!repo.listVmChatGrants) return unavailable();
    const rows = yield* repo.listVmChatGrants(vm.id);
    return { ok: true as const, value: rows.map(vmChatGrantView) };
  });
}

/** Share chat starts on the machine with a current teammate. Idempotent: an existing grant is kept. */
export function grantVmChat(input: VmChatGrantShareInput) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* requireUserVm(input);
    const target = input.targetUserId;
    if (target === "" || target.length > MAX_USER_ID_LENGTH || target !== target.trim()) {
      return refuse(400, "invalid_request", "Choose a teammate to share this machine with.");
    }
    if (!vmAcceptsChatGrants(vm)) return personalMachine();
    if (target === vm.userId) {
      return refuse(400, "vm_chat_grant_creator", "The machine's creator can always start chats on it.");
    }
    const access = yield* shareChatAccess(vm, input);
    if (!access.ok) return access;
    if (!access.value.memberIds.includes(target)) {
      return refuse(409, "vm_chat_grant_not_member", "Only a current member of this machine's team can be given chats on it.");
    }
    if (!repo.putVmChatGrant) return unavailable();
    const row = yield* repo.putVmChatGrant({ vmId: vm.id, userId: target, grantedBy: input.userId });
    return { ok: true as const, value: vmChatGrantView(row) };
  });
}

/** Take a share back. Idempotent: `revoked` is false when there was none. */
export function revokeVmChat(input: VmChatGrantShareInput) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* requireUserVm(input);
    const target = input.targetUserId;
    if (target === "" || target.length > MAX_USER_ID_LENGTH) {
      return refuse(400, "invalid_request", "Choose the teammate whose share to take back.");
    }
    // A personal-account machine never holds a grant.
    if (!vmAcceptsChatGrants(vm)) return { ok: true as const, value: { revoked: false } };
    const access = yield* shareChatAccess(vm, input);
    if (!access.ok) return access;
    if (!repo.deleteVmChatGrant) return unavailable();
    const revoked = yield* repo.deleteVmChatGrant({ vmId: vm.id, userId: target });
    return { ok: true as const, value: { revoked } };
  });
}

/**
 * share_chat: the creator who is still on the machine's team, or a team admin.
 * Answers the team's member list, which the grant's target is checked against.
 */
function shareChatAccess(
  vm: CloudVmRow,
  input: VmChatGrantShareInput,
): Effect.Effect<VmChatGrantOutcome<{ readonly memberIds: readonly string[] }>, never> {
  return Effect.gen(function* () {
    const lookup = yield* listTeamMemberIdsWithTimeout(input.teamDirectory, vm.ownerTeamId, STACK_READ_TIMEOUT_MS);
    if ("error" in lookup) return unavailable();
    const memberIds = lookup.memberIds;
    // A team that no longer exists, or a caller no longer on it, shares nothing.
    if (memberIds === null || !memberIds.includes(input.userId)) return forbidden();
    if (vm.userId === input.userId) return { ok: true as const, value: { memberIds } };
    const admin = yield* Effect.tryPromise({
      try: () => input.isTeamAdmin(vm.ownerTeamId, input.userId),
      catch: (cause) => cause,
    }).pipe(
      Effect.timeout(STACK_READ_TIMEOUT_MS),
      Effect.map((isAdmin) => isAdmin === true ? "admin" as const : "member" as const),
      Effect.catchAll(() => Effect.succeed("unknown" as const)),
    );
    if (admin === "unknown") return unavailable();
    return admin === "admin" ? { ok: true as const, value: { memberIds } } : forbidden();
  });
}


/** Stack's `team_admin` on the machine's team, through the billing admin check. Throws when Stack cannot answer. */
export function vmTeamAdminCheck(): VmTeamAdminCheck {
  return async (teamId, userId) => {
    const user = await getStackServerApp().getUser(userId);
    if (!user) return false;
    const access = await resolveTeamBillingAccess(user, teamId, { requireAdmin: true });
    if (access.ok) return true;
    if (access.error === "authorization_unavailable") throw new Error("team admin check unavailable");
    return false;
  };
}
