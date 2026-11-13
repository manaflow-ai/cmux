// l10n-allow-file: gallery fixtures, not shipped UI.
// Sample ledgers in the work-tracking format (skills/work-tracking/SKILL.md). Public-safe:
// made-up branches, paths and SHAs, no real user content.

export type AgentFixture = {
  id: string;
  name: string;
  harness: "Claude Code" | "Codex";
  workspace: string;
  live: boolean;
  updated: string;
  ledger: string;
};

const jsonl = (records: object[]) => records.map((r) => JSON.stringify(r)).join("\n");
const SHA = "4f2a9c1e";
const OLD = "b81d07aa";

const invites = jsonl([
  {
    kind: "task",
    id: "team-invites",
    title: "Invite teammates by link",
    goal: "Let a team admin share one link that adds people to the team, from Settings and from the phone.",
    branch: "feat-cmux-next-team-invite-link",
    pr: "https://github.com/example/cmux/pull/4182",
  },
  {
    kind: "capability",
    id: "invite-card",
    title: "Invite link card in Settings → Team",
    summary: "Admins create, copy and revoke one invite link; members see who invited them.",
    area: "Settings",
    status: "done",
    files: ["webviews/src/pages/settings/team/InviteCard.tsx", "web/app/api/teams/invites/route.ts"],
  },
  {
    kind: "decision",
    id: "link-expiry",
    title: "How long an invite link lives",
    chosen: "7 days, renewable by the admin",
    why: "A link pasted into a public channel stops working on its own; renewing is one click.",
    rejected: [
      { option: "Never expires", why: "A leaked link adds strangers until someone notices." },
      { option: "24 hours", why: "Teams in other time zones miss it; admins re-share daily." },
    ],
    for: ["invite-card"],
    needsHuman: true,
  },
  {
    kind: "decision",
    id: "token-storage",
    title: "How the server keeps the link token",
    chosen: "Only a SHA-256 hash of the token",
    why: "A database read cannot be turned into a working invite.",
    rejected: [{ option: "Plain token in the row", why: "Anyone with read access could join any team." }],
    for: ["invite-card"],
  },
  {
    kind: "evidence",
    id: "ev-card-light",
    type: "screenshot",
    path: "/tmp/agent-board-demo/invite-card-light.png",
    caption: "Invite card, admin, link active",
    sha: SHA,
    for: ["perm-card-mac-light"],
  },
  {
    kind: "evidence",
    id: "ev-card-dark",
    type: "screenshot",
    path: "/tmp/agent-board-demo/invite-card-dark.png",
    caption: "Same card in dark mode",
    sha: SHA,
    for: ["perm-card-mac-dark"],
  },
  {
    kind: "evidence",
    id: "ev-card-empty",
    type: "screenshot",
    path: "/tmp/agent-board-demo/invite-card-empty.png",
    caption: "No link yet: Create link button only",
    sha: OLD,
    for: ["perm-card-empty"],
  },
  {
    kind: "evidence",
    id: "ev-invite-tests",
    type: "test",
    url: "https://github.com/example/cmux/actions/runs/1",
    caption: "bun test settings/team/invites.test.tsx: 14 passed",
    sha: SHA,
    for: ["perm-card-revoked"],
  },
  {
    kind: "evidence",
    id: "ev-accept-video",
    type: "video",
    path: "/tmp/agent-board-demo/accept-flow.mp4",
    caption: "Open the link signed out, sign in, land in the team (0:41)",
    sha: SHA,
    for: ["perm-accept-signed-out"],
  },
  { kind: "permutation", id: "perm-card-mac-light", for: "invite-card", axes: { platform: "Mac", theme: "Light", state: "Active link" }, status: "verified", evidence: ["ev-card-light"] },
  { kind: "permutation", id: "perm-card-mac-dark", for: "invite-card", axes: { platform: "Mac", theme: "Dark", state: "Active link" }, status: "verified", evidence: ["ev-card-dark"] },
  { kind: "permutation", id: "perm-card-empty", for: "invite-card", axes: { platform: "Mac", theme: "Light", state: "Empty" }, status: "verified", evidence: ["ev-card-empty"] },
  { kind: "permutation", id: "perm-card-revoked", for: "invite-card", axes: { platform: "Mac", theme: "Light", state: "Revoked" }, status: "verified", evidence: ["ev-invite-tests"] },
  { kind: "permutation", id: "perm-card-error", for: "invite-card", axes: { platform: "Mac", theme: "Light", state: "Offline" }, status: "unverified", note: "No way to fake the Cloud service being down in the gallery yet." },
  {
    kind: "capability",
    id: "accept-flow",
    title: "Accept an invite from the link",
    summary: "The link opens cmux, signs in if needed and joins the team, with a clear error for an expired link.",
    area: "Teams",
    status: "done",
  },
  { kind: "permutation", id: "perm-accept-signed-out", for: "accept-flow", axes: { platform: "Mac", theme: "Light", state: "Signed out" }, status: "verified", evidence: ["ev-accept-video"] },
  { kind: "permutation", id: "perm-accept-expired", for: "accept-flow", axes: { platform: "Mac", theme: "Light", state: "Expired link" }, status: "broken", note: "Shows a blank sheet instead of the expired message; fix in progress." },
  { kind: "permutation", id: "perm-accept-iphone", for: "accept-flow", axes: { platform: "iPhone", theme: "Dark", state: "Signed in" }, status: "unverified", note: "Simulator pairing rig was busy." },
  {
    kind: "decision",
    id: "accept-already-member",
    title: "Opening a link for a team you are already in",
    chosen: "Open the team, say “You're already a member”",
    rejected: [{ option: "Show an error", why: "Nothing went wrong from the person's side." }],
    for: ["accept-flow"],
  },
  {
    kind: "capability",
    id: "ios-share",
    title: "Share the invite from the iPhone",
    summary: "Team screen on iPhone gets a Share invite button using the system share sheet.",
    area: "iPhone",
    status: "building",
  },
  { kind: "permutation", id: "perm-share-iphone-light", for: "ios-share", axes: { platform: "iPhone", theme: "Light", state: "Share sheet" }, status: "unverified" },
]);

const sidebar = jsonl([
  {
    kind: "task",
    id: "sidebar-1000",
    title: "Sidebar with 1,000 workspaces",
    goal: "Keep sidebar selection under 10 ms p95 with 1,000 workspaces.",
    branch: "feat-cmux-next-sidebar-virtual",
  },
  {
    kind: "capability",
    id: "virtual-rows",
    title: "Only visible sidebar rows are built",
    summary: "Rows outside the viewport are recycled; selection and drag keep working.",
    area: "Sidebar",
    status: "done",
  },
  {
    kind: "decision",
    id: "fixed-row-height",
    title: "Row height model",
    chosen: "Fixed height per density, measured once",
    why: "Chromium's list views do the same; variable heights need a second layout pass per scroll.",
    rejected: [
      { option: "Measure every row", why: "2.4 ms per scroll frame at 1,000 rows." },
      { option: "Estimate then correct", why: "Visible jumps when a group expands." },
    ],
    for: ["virtual-rows"],
  },
  { kind: "evidence", id: "ev-bench", type: "log", path: "/tmp/agent-board-demo/sidebar-bench.txt", caption: "select p95: 3.1 ms (was 41 ms) at 1,000 workspaces", sha: SHA, for: ["perm-1000"] },
  { kind: "evidence", id: "ev-build", type: "build", url: "https://github.com/example/cmux/actions/runs/2", caption: "Fleet build, tag sidebar-virtual", sha: SHA, for: ["perm-10", "perm-100"] },
  { kind: "permutation", id: "perm-10", for: "virtual-rows", axes: { workspaces: "10", density: "Comfortable" }, status: "verified", evidence: ["ev-build"] },
  { kind: "permutation", id: "perm-100", for: "virtual-rows", axes: { workspaces: "100", density: "Compact" }, status: "verified", evidence: ["ev-build"] },
  { kind: "permutation", id: "perm-1000", for: "virtual-rows", axes: { workspaces: "1,000", density: "Compact" }, status: "verified", evidence: ["ev-bench"] },
]);

const paste = jsonl([
  { kind: "task", id: "ios-paste", title: "Paste images into the iPhone composer", goal: "Pasting a photo attaches it instead of inserting a file path." },
  { kind: "capability", id: "paste-image", title: "Paste a copied photo", area: "iPhone", status: "done" },
  { kind: "permutation", id: "perm-photos", for: "paste-image", axes: { source: "Photos", theme: "Light" }, status: "verified", evidence: ["ev-paste"] },
  { kind: "permutation", id: "perm-files", for: "paste-image", axes: { source: "Files", theme: "Dark" }, status: "broken", note: "Files puts a private type first; still pastes the path." },
  { kind: "evidence", id: "ev-paste", type: "video", path: "/tmp/agent-board-demo/paste.mp4", caption: "Copy in Photos, paste in the composer (0:12)", sha: SHA, for: ["perm-photos"] },
]);

const starting = jsonl([
  { kind: "task", id: "cli-board", title: "Show the board from the cmux CLI", goal: "`cmux board` prints the same ledger in a terminal." },
  { kind: "capability", id: "cli-board-print", title: "cmux board prints capabilities", area: "CLI", status: "building" },
]);

export const AGENTS: AgentFixture[] = [
  { id: "a1", name: "team-invite-link", harness: "Claude Code", workspace: "Team invites", live: true, updated: "2m", ledger: invites },
  { id: "a2", name: "sidebar-virtual", harness: "Codex", workspace: "Sidebar perf", live: false, updated: "18m", ledger: sidebar },
  { id: "a3", name: "ios-paste-images", harness: "Claude Code", workspace: "iOS paste", live: false, updated: "1h", ledger: paste },
  { id: "a4", name: "cli-board", harness: "Codex", workspace: "CLI board", live: true, updated: "now", ledger: starting },
];

/** The same agents, with a malformed line in the first ledger (the error state). */
export const AGENTS_WITH_ERROR: AgentFixture[] = AGENTS.map((agent, i) =>
  i === 0
    ? {
        ...agent,
        ledger: `${agent.ledger}\n{"kind":"permutation","id":"perm-card-ipad",for:"invite-card"}\n{"kind":"evidence","id":"Bad ID","type":"screenshot","path":"/tmp/x.png"}`,
      }
    : agent,
);

/** Long names, many items: the worst case for layout. */
export const AGENTS_STRESS: AgentFixture[] = [
  ...AGENTS,
  ...Array.from({ length: 14 }, (_, i) => ({
    id: `s${i}`,
    name: `agent-with-a-very-long-branch-name-number-${i + 1}-that-keeps-going`,
    harness: (i % 2 ? "Codex" : "Claude Code") as AgentFixture["harness"],
    workspace: `Workspace ${i + 1}`,
    live: i % 3 === 0,
    updated: `${i + 3}h`,
    ledger: starting,
  })),
];
