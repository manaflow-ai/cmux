import type { HexclaveWebhookOutcome } from "../../db/schema";
import type { HexclaveMirrorStore } from "../../services/auth/hexclave/mirrorStore";
import type {
  HexclaveProjectPermission,
  HexclaveServerTeam,
  HexclaveServerUser,
  HexclaveSource,
  HexclaveTeamPermission,
} from "../../services/auth/hexclave/serverApi";

/** A mutable stand-in for Hexclave: the test edits it, reconciles read it. */
export class FakeHexclave implements HexclaveSource {
  users = new Map<string, HexclaveServerUser>();
  teams = new Map<string, HexclaveServerTeam>();
  /** `${teamId}:${userId}` */
  memberships = new Set<string>();
  teamPermissions: HexclaveTeamPermission[] = [];
  projectPermissions: HexclaveProjectPermission[] = [];
  failNext: Error | null = null;
  calls: string[] = [];

  private check(call: string) {
    this.calls.push(call);
    if (this.failNext) {
      const error = this.failNext;
      this.failNext = null;
      throw error;
    }
  }

  addMember(teamId: string, userId: string) { this.memberships.add(`${teamId}:${userId}`); }
  removeMember(teamId: string, userId: string) {
    this.memberships.delete(`${teamId}:${userId}`);
    this.teamPermissions = this.teamPermissions.filter((p) => !(p.team_id === teamId && p.user_id === userId));
  }
  deleteUser(userId: string) {
    this.users.delete(userId);
    for (const key of [...this.memberships]) if (key.endsWith(`:${userId}`)) this.memberships.delete(key);
    this.teamPermissions = this.teamPermissions.filter((p) => p.user_id !== userId);
    this.projectPermissions = this.projectPermissions.filter((p) => p.user_id !== userId);
  }
  deleteTeam(teamId: string) {
    this.teams.delete(teamId);
    for (const key of [...this.memberships]) if (key.startsWith(`${teamId}:`)) this.memberships.delete(key);
    this.teamPermissions = this.teamPermissions.filter((p) => p.team_id !== teamId);
  }

  getUser = async (userId: string) => { this.check(`getUser:${userId}`); return this.users.get(userId) ?? null; };
  getTeam = async (teamId: string) => { this.check(`getTeam:${teamId}`); return this.teams.get(teamId) ?? null; };
  listUserTeams = async (userId: string) => {
    this.check(`listUserTeams:${userId}`);
    return [...this.memberships]
      .filter((key) => key.endsWith(`:${userId}`))
      .map((key) => this.teams.get(key.split(":")[0]!))
      .filter((team): team is HexclaveServerTeam => !!team);
  };
  listUserTeamPermissions = async (userId: string) => {
    this.check(`listUserTeamPermissions:${userId}`);
    return this.teamPermissions.filter((p) => p.user_id === userId);
  };
  listUserProjectPermissions = async (userId: string) => {
    this.check(`listUserProjectPermissions:${userId}`);
    return this.projectPermissions.filter((p) => p.user_id === userId);
  };
  listUsersPage = async (cursor: string | null, limit: number) => page([...this.users.values()], cursor, limit);
  listTeamsPage = async (cursor: string | null, limit: number) => page([...this.teams.values()], cursor, limit);
}

function page<T extends { id: string }>(items: T[], cursor: string | null, limit: number) {
  const start = cursor ? items.findIndex((item) => item.id === cursor) + 1 : 0;
  const slice = items.slice(start, start + limit);
  const more = start + limit < items.length;
  return { items: slice, nextCursor: more ? slice.at(-1)!.id : null };
}

/** In-memory mirror with the Drizzle store's semantics (tombstones, cascades, insert-only teams from user reads). */
export class MemoryMirror implements HexclaveMirrorStore {
  users = new Map<string, HexclaveServerUser>();
  teams = new Map<string, HexclaveServerTeam>();
  memberships = new Set<string>();
  teamPermissions = new Set<string>();
  projectPermissions = new Set<string>();
  tombstones = new Set<string>();
  events = new Map<string, { eventType: string; outcome: HexclaveWebhookOutcome; processed: boolean; attempts: number }>();

  teamIdsFor(userId: string): string[] {
    return [...this.memberships].filter((key) => key.endsWith(`:${userId}`)).map((key) => key.split(":")[0]!).sort();
  }

  private dropUser(userId: string) {
    this.users.delete(userId);
    for (const key of [...this.memberships]) if (key.endsWith(`:${userId}`)) this.memberships.delete(key);
    for (const key of [...this.teamPermissions]) if (key.split(":")[1] === userId) this.teamPermissions.delete(key);
    for (const key of [...this.projectPermissions]) if (key.startsWith(`${userId}:`)) this.projectPermissions.delete(key);
  }

  reconcileUser: HexclaveMirrorStore["reconcileUser"] = async (userId, read) => {
    const state = await read();
    const previousTeamIds = this.teamIdsFor(userId);
    if (state.kind === "gone") {
      this.tombstones.add(`user:${userId}`);
      this.dropUser(userId);
      return { state, previousTeamIds, currentTeamIds: [] };
    }
    this.tombstones.delete(`user:${userId}`);
    this.dropUser(userId);
    this.users.set(userId, state.user);
    const live = state.teams.filter((team) => !this.tombstones.has(`team:${team.id}`));
    for (const team of live) if (!this.teams.has(team.id)) this.teams.set(team.id, team);
    const liveIds = new Set(live.map((team) => team.id));
    for (const id of liveIds) this.memberships.add(`${id}:${userId}`);
    for (const p of state.teamPermissions) if (liveIds.has(p.team_id)) this.teamPermissions.add(`${p.team_id}:${userId}:${p.id}`);
    for (const p of state.projectPermissions) this.projectPermissions.add(`${userId}:${p.id}`);
    return { state, previousTeamIds, currentTeamIds: [...liveIds].sort() };
  };

  reconcileTeam: HexclaveMirrorStore["reconcileTeam"] = async (teamId, read) => {
    const team = await read();
    const memberIds = [...this.memberships].filter((key) => key.startsWith(`${teamId}:`)).map((key) => key.split(":")[1]!);
    if (!team) {
      this.tombstones.add(`team:${teamId}`);
      this.teams.delete(teamId);
      for (const key of [...this.memberships]) if (key.startsWith(`${teamId}:`)) this.memberships.delete(key);
      for (const key of [...this.teamPermissions]) if (key.startsWith(`${teamId}:`)) this.teamPermissions.delete(key);
      return { team: null, memberIds };
    }
    this.tombstones.delete(`team:${teamId}`);
    this.teams.set(teamId, team);
    return { team, memberIds };
  };

  listMirroredIds: HexclaveMirrorStore["listMirroredIds"] = async () => ({
    userIds: [...this.users.keys()],
    teamIds: [...this.teams.keys()],
  });

  isEventProcessed: HexclaveMirrorStore["isEventProcessed"] = async (svixId) => this.events.get(svixId)?.processed ?? false;

  recordEvent: HexclaveMirrorStore["recordEvent"] = async ({ svixId, eventType, outcome }) => {
    const existing = this.events.get(svixId);
    const processed = existing?.processed || outcome === "processed" || outcome === "ignored";
    this.events.set(svixId, {
      eventType,
      outcome: existing?.processed ? existing.outcome : outcome,
      processed,
      attempts: (existing?.attempts ?? 0) + 1,
    });
  };
}
