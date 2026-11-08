/**
 * The scenario catalogue (plans/cmux-next/cloud-selftest-DESIGN.md §5). Each scenario is data: actors with their team
 * roles, steps (actor, action, args, expect), and the edge cases it covers. A step whose verb a lane still has to add
 * runs once that lane's verb is in the cmux under test, and is PENDING-<lane> until then.
 *
 * Actor names keep one role in the whole catalogue: owner (team owner), admin, member, member2, leaver (a member who
 * is removed mid-run), guest (signed in, outside the team, joins by link), outsider (signed in, no relation).
 */
import type { ActorSpec, Scenario, Step } from "./engine";

const OWNER: ActorSpec = { name: "owner", team_role: "owner" };
const ADMIN: ActorSpec = { name: "admin", team_role: "admin" };
const MEMBER: ActorSpec = { name: "member", team_role: "member" };
const MEMBER2: ActorSpec = { name: "member2", team_role: "member" };
const LEAVER: ActorSpec = { name: "leaver", team_role: "member" };
const GUEST: ActorSpec = { name: "guest", team_role: null };
const OUTSIDER: ActorSpec = { name: "outsider", team_role: null };

const s = (actor: string, action: string, args?: Step["args"], expect?: Step["expect"], more: Partial<Step> = {}): Step => ({ actor, action, ...(args ? { args } : {}), ...(expect ? { expect } : {}), ...more });
const listed = (role: string) => ({ teams: { $contains: { id: "${team}", role } } });
/** The chat address of C5: cloud:<team>/<vm>/<session>. */
const CHAT = "cloud:${team}/${vm}/${session}";
/** A machine and an agent session on it, with the model stub on its loopback, as the owner. */
/** The stub's reply names the prompt's `[st-N]` tag, so a step can tell which turn answered. */
const ECHO = { version: 1, steps: [{ text: "Stub reply {{nonce}}: {{prompt~(\\[st-[^\\]]+\\])}}" }] };
const machineWithChat = (script?: unknown): Step[] => [
  s("owner", "machine.create", {}, { ok: true, json: { machine_id: { $exists: true } } }, { save: { vm: "machine_id" } }),
  s("owner", "machine.get", { machine: "${vm}" }, { json: { status: "running" }, within_ms: 300_000, every_ms: 3_000 }, { label: "owner: machine running" }),
  s("owner", "vm.stub", { machine: "${vm}", script: script ?? ECHO }),
  s("owner", "chat.start", { machine: "${vm}", session: "${session}" }),
];
/**
 * A gateway turn needs the machine's agents pointed at the model edge (the login-free VM's base URLs, lane A). Without
 * it Claude Code reports "Not logged in" (auth.signed_out) and the gateway is never asked, so say that first. Read from
 * the agent daemon's own environment (what its agents inherit), after the chat starts it.
 */
const edgeRouted = s("owner", "vm.credentials", { machine: "${vm}" }, { json: { daemon_seen: true, daemon_anthropic_base_url: { $re: "^https?://" }, daemon_auth_env: { $contains: { $oneOf: ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"] } } } }, { label: "owner: the machine's agents reach models at the edge (login-free VM, lane A)" });
const deleteVm: Step[] = [s("owner", "machine.delete", { machine: "${vm}" }, { ok: true }, { label: "owner: delete the machine (cleanup)" })];

export const SCENARIOS: Scenario[] = [
  {
    name: "identity.isolated",
    summary: "each actor is its own signed-in account with its own HOME; one actor's token is never another's",
    covers: ["multi-actor isolation", "guest vs member vs admin vs non-member"],
    tags: ["identity", "fast"],
    actors: [OWNER, MEMBER, OUTSIDER],
    steps: [
      s("owner", "auth.probe", { token: "own" }, { ok: true, json: { teams: { $contains: { kind: "personal" } } } }),
      s("member", "auth.probe", { token: "own" }, { ok: true }),
      s("outsider", "auth.probe", { token: "own" }, { ok: true, json: { teams: { $not: { $contains: { id: "${team}" } } } } }),
    ],
  },
  {
    name: "team.list",
    summary: "owner, admin and member each list the team with their role; an outsider does not see it",
    covers: ["team list", "guest vs member vs admin vs non-member"],
    tags: ["team", "fast"],
    actors: [OWNER, ADMIN, MEMBER, OUTSIDER],
    steps: [
      s("owner", "team.list", {}, { json: listed("owner") }),
      s("admin", "team.list", {}, { json: listed("admin") }),
      s("member", "team.list", {}, { json: listed("member") }),
      s("outsider", "team.list", {}, { json: { teams: { $not: { $contains: { id: "${team}" } } } } }),
    ],
  },
  {
    name: "team.role_matrix",
    summary: "who may read the team and its machines: owner, admin, member yes; a non-member is refused team.not_member",
    covers: ["role matrix", "guest vs member vs admin vs non-member"],
    tags: ["team", "fast"],
    actors: [OWNER, ADMIN, MEMBER, OUTSIDER],
    steps: [
      s("owner", "team.members", {}, { json: { members: { $contains: { user: "${member.user}", role: "member" } } } }),
      s("admin", "team.members", {}, { json: { members: { $contains: { user: "${admin.user}", role: "admin" } } } }),
      s("member", "team.members", {}, { json: { members: { $contains: { user: "${owner.user}", role: "owner" } } } }),
      s("outsider", "team.members", { team: "${team}" }, { error: "team.not_member" }),
      s("member", "machine.list", {}, { ok: true }),
    ],
  },
  {
    name: "auth.expired_revoked",
    summary: "an expired or garbage token is refused auth.unauthenticated; after a revoke the refresh is refused",
    covers: ["expired/revoked tokens"],
    tags: ["auth", "fast"],
    actors: [OWNER, LEAVER],
    needs: ["fixtures.mutate"],
    steps: [
      s("owner", "auth.probe", { token: "expired" }, { error: "auth.unauthenticated" }),
      s("owner", "auth.probe", { token: "garbage" }, { error: "auth.unauthenticated" }),
      s("owner", "auth.probe", { token: "none" }, { error: "auth.unauthenticated" }),
      s("leaver", "auth.refresh", {}, { ok: true }, { label: "leaver: a refresh works before the revoke" }),
      s("harness", "fixtures.revoke_sessions", { user: "leaver" }, { ok: true }),
      s("leaver", "auth.refresh", {}, { error: "auth.refresh_refused", within_ms: 30_000 }),
    ],
  },
  {
    name: "team.member_removed_live",
    summary: "a member removed from the team loses access on their next request (no restart), and the team list drops it",
    covers: ["member removed mid-session (access revoked live)", "following then losing access"],
    tags: ["team", "revoke"],
    actors: [OWNER, LEAVER],
    needs: ["fixtures.mutate"],
    steps: [
      s("leaver", "team.members", {}, { ok: true }, { label: "leaver: reads the team while a member" }),
      s("harness", "fixtures.remove", { user: "leaver" }, { ok: true }),
      // With the Worker fixtures route TeamDO syncs before it answers; through the sign-in service it waits for its webhook.
      s("leaver", "team.members", { team: "${team}" }, { error: "team.not_member", within_ms: 120_000, every_ms: 5_000 }, { label: "leaver: refused once removed" }),
      s("leaver", "team.list", {}, { json: { teams: { $not: { $contains: { id: "${team}" } } } }, within_ms: 60_000 }),
      s("owner", "team.members", {}, { json: { members: { $not: { $contains: { user: "${leaver.user}" } } } } }),
    ],
  },
  {
    name: "vm.login_free",
    summary: "a new Cloud machine holds no provider login: no login files, only placeholder keys, base URLs at the edge",
    covers: ["login-free VM (no credential files on the VM)"],
    tags: ["vm", "machine"],
    actors: [OWNER],
    needs: ["machine"],
    steps: [
      s("owner", "machine.create", {}, { json: { machine_id: { $exists: true } } }, { save: { vm: "machine_id" } }),
      s("owner", "machine.get", { machine: "${vm}" }, { json: { status: "running" }, within_ms: 300_000, every_ms: 3_000 }),
      s("owner", "vm.credentials", { machine: "${vm}" }, { json: { files: [], real_env: [], anthropic_base_url: { $re: "^(https://coderouter\\.cmux\\.internal|$)" } } }),
      s("owner", "vm.auth_status", { machine: "${vm}" }, { json: { holds_login: false } }),
    ],
    finally: deleteVm,
  },
  {
    name: "vm.chat_sleep_wake",
    summary: "a turn on the stub, then the VM sleeps and wakes, and the next turn keeps the session (history once, in order)",
    covers: ["VM asleep or waking", "large transcripts (history read back)"],
    tags: ["vm", "machine", "chat"],
    actors: [OWNER],
    needs: ["machine"],
    steps: [
      ...machineWithChat(),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-1] first" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-1\\]" } } }),
      s("owner", "machine.pause", { machine: "${vm}" }),
      s("owner", "machine.get", { machine: "${vm}" }, { json: { status: { $oneOf: ["paused", "suspended", "stopped"] } }, within_ms: 180_000, every_ms: 3_000 }),
      s("owner", "machine.resume", { machine: "${vm}" }),
      s("owner", "machine.get", { machine: "${vm}" }, { json: { status: "running" }, within_ms: 300_000, every_ms: 3_000 }),
      s("owner", "vm.stub", { machine: "${vm}", script: ECHO }, { ok: true }, { label: "owner: the stub again (processes do not survive a pause)" }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-2] after wake" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-2\\]" } } }),
      s("owner", "chat.history", { machine: "${vm}", session: "${session}" }, { json: { count: 2, turns: [{ prompt: { $re: "^\\[st-1\\]" } }, { prompt: { $re: "^\\[st-2\\]" } }] } }),
    ],
    finally: deleteVm,
  },
  {
    name: "vm.restart_mid_turn",
    summary: "the agent daemon dies mid-turn (a VM restart as the session sees it); it comes back with the session and no duplicate prompt",
    covers: ["VM restarted mid-turn", "network drop and resume without losing or duplicating messages"],
    tags: ["vm", "machine", "chat"],
    actors: [OWNER],
    needs: ["machine"],
    steps: [
      ...machineWithChat({ version: 1, steps: [{ text: "slow {{nonce}} {{prompt~(\\[st-[^\\]]+\\])}}", delay_ms: 20_000 }] }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-r1] slow turn" }),
      s("owner", "vm.daemon_kill", { machine: "${vm}" }, { json: { killed: { $exists: true } } }),
      s("owner", "chat.history", { machine: "${vm}", session: "${session}" }, { json: { turns: { $contains: { prompt: { $re: "^\\[st-r1\\]" } } } }, within_ms: 90_000, every_ms: 3_000 }, { label: "owner: the session is back with the prompt" }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-r2] after restart" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-r2\\]" } } }),
      s("owner", "chat.history", { machine: "${vm}", session: "${session}" }, { json: { turns: { $len: 2 } } }, { label: "owner: each prompt once" }),
    ],
    finally: deleteVm,
  },
  {
    name: "chat.large_transcript",
    summary: "a 200 KB prompt and 20 turns go through and read back whole",
    covers: ["large transcripts"],
    tags: ["chat", "machine"],
    actors: [OWNER],
    needs: ["machine"],
    steps: [
      ...machineWithChat(),
      s("owner", "chat.prompt_big", { machine: "${vm}", session: "${session}", marker: "[st-big]", bytes: 200_000 }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-big\\]" } } }),
      ...Array.from({ length: 19 }, (_, i) => [
        s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: `[st-${i + 2}] turn` }),
        s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: `\\[st-${i + 2}\\]` } } }),
      ]).flat(),
      s("owner", "chat.history", { machine: "${vm}", session: "${session}", limit: 50 }, { json: { count: 20 } }),
    ],
    finally: deleteVm,
  },
  {
    name: "gateway.offline_reconnect",
    summary: "no gateway: a turn ends inference.gateway_offline with clear copy; the gateway connects and the next turn passes; it drops and comes back",
    covers: ["gateway offline", "gateway reconnecting", "owner offline / Mac asleep"],
    tags: ["gateway", "machine"],
    actors: [OWNER],
    needs: ["machine", "gateway", "stub"],
    steps: [
      s("owner", "gateway.mode", { mode: "gateway" }, { ok: true }),
      s("owner", "gateway.status", {}, { json: { online: false } }),
      s("owner", "machine.create", {}, { json: { machine_id: { $exists: true } } }, { save: { vm: "machine_id" } }),
      s("owner", "machine.get", { machine: "${vm}" }, { json: { status: "running" }, within_ms: 300_000, every_ms: 3_000 }),
      s("owner", "chat.start", { machine: "${vm}", session: "${session}" }),
      edgeRouted,
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-off] no gateway" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}", timeout_ms: 240_000 }, { error: "inference.gateway_offline" }),
      s("owner", "gateway.start", { id: "g1" }),
      s("owner", "gateway.status", {}, { json: { online: true }, within_ms: 60_000 }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-on] gateway up" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-on\\]" } } }),
      s("owner", "gateway.stop", { id: "g1" }),
      s("owner", "gateway.status", {}, { json: { online: false }, within_ms: 90_000, every_ms: 5_000 }),
      s("owner", "gateway.start", { id: "g1" }),
      s("owner", "gateway.status", {}, { json: { online: true }, within_ms: 60_000 }),
      s("owner", "stub.calls", {}, { json: { count: { $gte: 1 } } }),
    ],
    finally: [s("owner", "gateway.stop", { id: "g1" }), s("owner", "gateway.mode", { mode: "off" }), ...deleteVm],
  },
  {
    name: "gateway.route_order",
    summary: "a machine's route follows the documented order: the owner's personal gateway before the team's",
    covers: ["team shared keys (route order)", "two gateways for one owner"],
    tags: ["gateway", "machine"],
    actors: [OWNER],
    needs: ["machine"],
    steps: [
      s("owner", "machine.create", {}, { json: { machine_id: { $exists: true } } }, { save: { vm: "machine_id" } }),
      s("owner", "machine.get", { machine: "${vm}" }, { json: { status: "running" }, within_ms: 300_000, every_ms: 3_000 }),
      s("owner", "gateway.mode", { mode: "gateway" }, { ok: true }),
      s("owner", "gateway.route", { machine: "${vm}" }, { json: { route: "team_gateway" } }),
      s("owner", "gateway.mode", { mode: "gateway", personal: true }, { ok: true }),
      s("owner", "gateway.status", { personal: true }, { json: { mode: "gateway" } }),
      s("owner", "gateway.route", { machine: "${vm}" }, { json: { route: "owner_gateway" } }),
    ],
    finally: [s("owner", "gateway.mode", { mode: "off", personal: true }), s("owner", "gateway.mode", { mode: "off" }), ...deleteVm],
  },
  {
    name: "gateway.two_gateways",
    summary: "two gateways for one team: either answers, and one going away loses no turn",
    covers: ["two gateways for one owner"],
    tags: ["gateway", "machine"],
    actors: [OWNER],
    needs: ["machine", "gateway", "stub"],
    steps: [
      s("owner", "gateway.mode", { mode: "gateway" }, { ok: true }),
      s("owner", "gateway.start", { id: "a" }),
      s("owner", "gateway.start", { id: "b" }),
      s("owner", "gateway.status", {}, { json: { online: true }, within_ms: 60_000 }),
      s("owner", "machine.create", {}, { json: { machine_id: { $exists: true } } }, { save: { vm: "machine_id" } }),
      s("owner", "machine.get", { machine: "${vm}" }, { json: { status: "running" }, within_ms: 300_000, every_ms: 3_000 }),
      s("owner", "chat.start", { machine: "${vm}", session: "${session}" }),
      edgeRouted,
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-2g-1] both up" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-2g-1\\]" } } }),
      s("owner", "gateway.stop", { id: "a" }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-2g-2] one left" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-2g-2\\]" } } }),
    ],
    finally: [s("owner", "gateway.stop", { id: "b" }), s("owner", "gateway.mode", { mode: "off" }), ...deleteVm],
  },
  {
    name: "gateway.provider_errors",
    summary: "the subscription's rate limit, auth error and overload reach the chat as typed errors; a retry after them answers",
    covers: ["provider rate-limit and auth errors surfaced with clear copy", "idempotent retries"],
    tags: ["gateway", "machine"],
    actors: [OWNER],
    needs: ["machine", "gateway", "stub"],
    steps: [
      s("owner", "gateway.mode", { mode: "gateway" }, { ok: true }),
      s("owner", "gateway.start", { id: "g1" }),
      s("owner", "gateway.status", {}, { json: { online: true }, within_ms: 60_000 }),
      s("owner", "machine.create", {}, { json: { machine_id: { $exists: true } } }, { save: { vm: "machine_id" } }),
      s("owner", "machine.get", { machine: "${vm}" }, { json: { status: "running" }, within_ms: 300_000, every_ms: 3_000 }),
      s("owner", "chat.start", { machine: "${vm}", session: "${session}" }),
      edgeRouted,
      s("harness", "stub.fault", { faults: [{ status: 429, type: "rate_limit_error", message: "rate limited", retry_after: 1, count: 20 }] }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-429] limited" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { error: "provider.rate_limited" }),
      s("harness", "stub.fault", { faults: [{ status: 401, type: "authentication_error", message: "login expired", count: 20 }] }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-401] auth" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { error: "provider.auth" }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-ok] after" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-ok\\]" } } }),
    ],
    finally: [s("owner", "gateway.stop", { id: "g1" }), s("owner", "gateway.mode", { mode: "off" }), ...deleteVm],
  },
  {
    name: "share.cloud_chat_guest",
    summary: "the owner shares a Cloud chat; an outside guest joins by link, their prompt is held until the owner lets it in, with the guest's author stamp",
    covers: ["Cloud chat share", "guest vs member", "author stamps", "queue/held state"],
    tags: ["share", "machine"],
    actors: [OWNER, GUEST],
    needs: ["machine"],
    steps: [
      ...machineWithChat(),
      s("owner", "share.create", { session: CHAT }, { json: { link: { $re: "^https?://|^cmux://" } } }, { save: { link: "link", share_id: "share_id" } }),
      s("guest", "share.join", { link: "${link}" }, { json: { role: { $oneOf: ["guest", "view"] } } }),
      s("guest", "chat.steer", { session: CHAT, text: "[st-g] from the guest" }, { json: { held: true } }, { save: { held_id: "prompt_id" } }),
      s("owner", "chat.attach", { session: CHAT }, { json: { held: { $contains: { prompt_id: "${held_id}", author: { user: "${guest.user}" } } } } }),
      s("owner", "chat.approve", { session: CHAT, prompt_id: "${held_id}" }, { ok: true }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-g\\]" } } }),
      s("owner", "share.revoke", { share_id: "${share_id}" }, { ok: true }),
      s("guest", "chat.steer", { session: CHAT, text: "[st-g2] after revoke" }, { error: ["share.revoked", "auth.forbidden"] }),
    ],
    finally: deleteVm,
  },
  {
    name: "share.member_attach_steer",
    summary: "a teammate attaches to the owner's Cloud chat and steers the running turn directly; presence, typing and author stamps show",
    covers: ["teammate attach + steer", "two people prompting at once", "presence", "author stamps"],
    tags: ["share", "team", "machine"],
    actors: [OWNER, MEMBER, MEMBER2],
    needs: ["machine"],
    steps: [
      ...machineWithChat({ version: 1, steps: [{ text: "slow {{nonce}} {{prompt~(\\[st-[^\\]]+\\])}}", delay_ms: 15_000 }] }),
      s("member", "team.sessions", {}, { json: { sessions: { $contains: { session: CHAT } } } }),
      s("member", "chat.attach", { session: CHAT }, { json: { presence: { $contains: { user: "${member.user}" } } } }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-o] owner's turn" }),
      s("member", "chat.steer", { session: CHAT, text: "[st-m] member steers", idempotency_key: "${run}-steer-m" }, { json: { held: false, steered: true } }, { concurrent: true }),
      s("member2", "chat.steer", { session: CHAT, text: "[st-m2] at the same time", idempotency_key: "${run}-steer-m2" }, { json: { held: false } }, { concurrent: true }),
      s("member", "chat.steer", { session: CHAT, text: "[st-m] member steers", idempotency_key: "${run}-steer-m" }, { json: { duplicate: true } }, { label: "member: the same send again is not a second prompt" }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { ok: true }),
      s("owner", "chat.events", { machine: "${vm}", session: "${session}" }, { json: { authors: { $contains: "${member.user}" } } }),
      s("owner", "chat.history", { machine: "${vm}", session: "${session}" }, { json: { turns: { $contains: { prompt: { $re: "^\\[st-m\\]" }, author: { user: "${member.user}" } } } } }),
    ],
    finally: deleteVm,
  },
  {
    name: "share.follow_then_removed",
    summary: "a member follows a teammate's chat, is removed from the team, and the follow ends with access revoked; their next attach is refused",
    covers: ["following then losing access", "member removed mid-session (access revoked live)"],
    tags: ["share", "team", "revoke", "machine"],
    actors: [OWNER, LEAVER],
    needs: ["machine", "fixtures.mutate"],
    steps: [
      ...machineWithChat(),
      s("leaver", "chat.follow", { session: CHAT }, { ok: true }),
      s("harness", "fixtures.remove", { user: "leaver" }),
      s("leaver", "chat.attach", { session: CHAT }, { error: ["team.not_member", "auth.forbidden"], within_ms: 120_000, every_ms: 5_000 }),
    ],
    finally: deleteVm,
  },
  {
    name: "chat.reassign_transfer_mid_turn",
    summary: "reassigning a chat while its turn runs, then bringing it back to this Mac while a turn runs: no turn is lost or doubled",
    covers: ["reassigning while a turn runs", "transfer while a turn is running"],
    tags: ["team", "machine"],
    actors: [OWNER, MEMBER],
    needs: ["machine"],
    steps: [
      ...machineWithChat({ version: 1, steps: [{ text: "slow {{nonce}} {{prompt~(\\[st-[^\\]]+\\])}}", delay_ms: 15_000 }] }),
      s("owner", "chat.send", { machine: "${vm}", session: "${session}", text: "[st-ra] running" }),
      s("owner", "chat.reassign", { session: CHAT, to: "${member.user}" }, { json: { owner: "${member.user}" } }),
      s("member", "chat.attach", { session: CHAT }, { json: { owner: "${member.user}" } }),
      s("owner", "chat.wait", { machine: "${vm}", session: "${session}" }, { json: { reply: { $re: "\\[st-ra\\]" } } }),
      s("member", "chat.steer", { session: CHAT, text: "[st-tr] running at transfer" }),
      s("member", "chat.transfer_local", { session: CHAT }, { json: { turns: { $gte: 2 }, running_turn: { $oneOf: ["finished", "carried"] } } }),
    ],
    finally: deleteVm,
  },
  {
    name: "links.cloud_session",
    summary: "a Cloud chat's link is cmux://cloud/session/<team>/<vm>/<session> and opens the same chat for a member, not for an outsider",
    covers: ["links", "guest vs member vs non-member"],
    tags: ["links", "machine"],
    actors: [OWNER, MEMBER, OUTSIDER],
    needs: ["machine"],
    steps: [
      ...machineWithChat(),
      s("owner", "link.session", { session: CHAT }, { json: { url: "cmux://cloud/session/${team}/${vm}/${session}" } }, { save: { url: "url" } }),
      s("member", "link.session", { url: "${url}" }, { json: { session: CHAT, can_open: true } }),
      s("outsider", "link.session", { url: "${url}" }, { json: { can_open: false } }),
    ],
    finally: deleteVm,
  },
  {
    name: "team_keys.shared_path",
    summary: "an admin sets the team's shared key; a member's turn spends it (never the member's login); members cannot set or read it",
    covers: ["team shared key path", "role matrix"],
    tags: ["keys", "team", "machine"],
    actors: [OWNER, ADMIN, MEMBER],
    steps: [
      s("member", "team_keys.set", { agent: "claude", secret_file: "${keyfile}" }, { error: "auth.forbidden" }),
      s("admin", "team_keys.set", { agent: "claude", secret_file: "${keyfile}" }, { ok: true }),
      s("member", "team_keys.status", {}, { json: { claude: { set: true, secret: { $absent: true } } } }),
      s("owner", "team_keys.clear", { agent: "claude" }, { ok: true }),
      s("member", "team_keys.status", {}, { json: { claude: { set: false } } }),
    ],
  },
];
