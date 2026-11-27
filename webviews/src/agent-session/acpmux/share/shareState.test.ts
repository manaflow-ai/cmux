// l10n-allow-file: test fixtures.
import { afterEach, expect, test } from "bun:test";
import {
  forgetShareLinks,
  isAccount,
  shareClient,
  shareView,
  type ChatShare,
  normalAccount,
  inviteStep,
  type ShareView,
} from "./shareState";

const base: ChatShare = {
  shareId: "s",
  state: "active",
  url: null,
  inviteUrl: null,
  role: null,
  createdAt: 0,
  expiresAt: 0,
  usesLeft: 1,
  guests: [],
  invitees: [],
};

afterEach(forgetShareLinks);

test("a chat shared with nobody reads Restricted with only the owner", () => {
  expect(shareView([])).toEqual({
    people: [],
    teams: [],
    teamShares: [],
    general: "restricted",
    links: [],
    inviteUrl: null,
    guestsNow: 0,
  });
});

test("invitees across live shares are one row each; removed and ended ones are not", () => {
  const view = shareView([
    {
      ...base,
      shareId: "a",
      createdAt: 1,
      inviteUrl: "https://room/i/a",
      invitees: [
        { account: "ana@example.com", role: "talk", state: "invited", joined: false },
        { account: "@gone", role: "view", state: "removed", joined: false },
      ],
      guests: [{ guestId: "g", name: "Ana", account: "ana@example.com", role: "talk", joined: true }],
    },
    {
      ...base,
      shareId: "b",
      createdAt: 2,
      inviteUrl: "https://room/i/b",
      invitees: [{ account: "ana@example.com", role: "talk", state: "invited", joined: false }],
    },
    {
      ...base,
      shareId: "c",
      state: "revoked",
      invitees: [{ account: "@old", role: "view", state: "invited", joined: false }],
    },
  ]);
  expect(view.people).toEqual([{ account: "ana@example.com", role: "talk", joined: true, opened: true }]);
  expect(view.inviteUrl).toBe("https://room/i/b");
  expect(view.general).toBe("restricted");
});

// An invite nobody has opened yet is pending: the row says "Hasn't opened it yet" (opened false),
// while someone who joined and left is neither pending nor in the chat now.
test("an invitee with no guest record is pending; one who left has opened it", () => {
  const view = shareView([
    {
      ...base,
      shareId: "p",
      invitees: [
        { account: "@new", role: "view", state: "invited", joined: false },
        { account: "@left", role: "talk", state: "invited", joined: false },
      ],
      guests: [{ guestId: "g", name: "Left", account: "@left", role: "talk", joined: false }],
    },
  ]);
  expect(view.people).toEqual([
    { account: "@new", role: "view", joined: false, opened: false },
    { account: "@left", role: "talk", joined: false, opened: true },
  ]);
});

test("normalAccount compares accounts as the daemon does", () => {
  expect(normalAccount("  Ana@Example.COM ")).toBe("ana@example.com");
  expect(normalAccount("@Sam")).toBe("@sam");
});

// Inviting someone already in People with access never makes a second row or a daemon refusal
// (share.invited): the same role says they have access; another role changes theirs.
test("Invite on someone with access says so, or changes their role", () => {
  const view: ShareView = {
    people: [{ account: "ana@example.com", role: "view", joined: false, opened: false }],
    general: "restricted",
    links: [],
    inviteUrl: null,
    guestsNow: 0,
  };
  expect(inviteStep(view, " Ana@Example.com", "view")).toEqual({ kind: "already", account: "ana@example.com" });
  expect(inviteStep(view, "ana@example.com", "talk")).toEqual({ kind: "role", account: "ana@example.com" });
  expect(inviteStep(view, "@sam", "view")).toEqual({ kind: "invite" });
});

test("a live viewer link is Anyone with the link; a Share with Guest link is not", () => {
  const viewer = {
    ...base,
    shareId: "v",
    role: "view" as const,
    guests: [{ guestId: "g", name: "R", account: null, role: "view" as const, joined: true }],
  };
  expect(shareView([viewer]).general).toBe("anyone");
  expect(shareView([viewer]).guestsNow).toBe(1);
  expect(shareView([{ ...base, shareId: "t" }]).general).toBe("restricted");
  expect(shareView([{ ...viewer, state: "expired" }]).general).toBe("restricted");
});

test("Copy link reuses the page's live viewer link, and Restricted revokes every viewer link", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const client = shareClient("chat", async (op, params) => {
    calls.push([op, params]);
    return op === "link" ? { shareId: "v1", url: "https://room/g/v1#secret" } : {};
  });
  const first = await client.viewerLink(shareView([]));
  expect(first).toBe("https://room/g/v1#secret");
  const live = shareView([{ ...base, shareId: "v1", role: "view" }]);
  expect(await client.viewerLink(live)).toBe(first);
  expect(calls.filter(([op]) => op === "link")).toHaveLength(1);
  await client.restrict(
    shareView([
      { ...base, shareId: "v1", role: "view" },
      { ...base, shareId: "v2", role: "view" },
    ]),
  );
  expect(calls.filter(([op]) => op === "revoke").map(([, p]) => p)).toEqual([
    { shareId: "v1", session: "chat" },
    { shareId: "v2", session: "chat" },
  ]);
  // After Restricted the kept link is gone: the next Anyone makes a new one.
  await client.viewerLink(live);
  expect(calls.filter(([op]) => op === "link")).toHaveLength(2);
});

test("a role change is uninvite then invite, in that order", async () => {
  const ops: string[] = [];
  await shareClient("chat", async (op) => void ops.push(op)).setRole("@sam", "talk");
  expect(ops).toEqual(["uninvite", "invite"]);
});

test("accounts are an email or an @handle", () => {
  expect(isAccount("ana@example.com")).toBe(true);
  expect(isAccount(" @sam ")).toBe(true);
  expect(isAccount("sam")).toBe(false);
  expect(isAccount("@")).toBe(false);
});

test("a viewer link that also holds invite records is still Anyone, and Restricted revokes it", async () => {
  const mixed: ChatShare = {
    ...base,
    shareId: "v",
    role: "view",
    invitees: [{ account: "@gone", role: "view", state: "removed", joined: false }],
  };
  const view = shareView([mixed]);
  expect(view.general).toBe("anyone");
  const revoked: unknown[] = [];
  await shareClient("chat", async (op, params) => void (op === "revoke" && revoked.push(params))).restrict(view);
  expect(revoked).toEqual([{ shareId: "v", session: "chat" }]);
});

test("every op names the chat it is for", async () => {
  const seen: unknown[] = [];
  const client = shareClient("chat-a", async (_op, params) => void seen.push(params));
  await client.invite("@sam", "view");
  await client.state().catch(() => undefined);
  expect(seen).toEqual([{ account: "@sam", role: "view", session: "chat-a" }, { session: "chat-a" }]);
});

test("Restricted re-reads the daemon and ends a viewer link made after the dialog's read", async () => {
  // Another dialog makes v2 after this dialog read only v1.
  let live = ["v1", "v2"];
  const revoked: string[] = [];
  const client = shareClient("chat", async (op, params) => {
    if (op === "revoke") {
      revoked.push(params?.shareId as string);
      live = live.filter((id) => id !== params?.shareId);
    }
    if (op === "state") return { shares: live.map((shareId) => ({ ...base, shareId, role: "view" })) };
    return {};
  });
  await client.restrict(shareView([{ ...base, shareId: "v1", role: "view" }]));
  expect(revoked).toEqual(["v1", "v2"]);
  expect(live).toEqual([]);
});

test("a viewer link the daemon made with no room is ended, not left live", async () => {
  const ops: [string, unknown][] = [];
  const client = shareClient("chat", async (op, params) => {
    ops.push([op, params]);
    return op === "link" ? { shareId: "orphan", url: null } : {};
  });
  await expect(client.viewerLink(shareView([]))).rejects.toThrow("share.no_room");
  expect(ops).toEqual([
    ["link", { role: "view", session: "chat" }],
    ["revoke", { shareId: "orphan", session: "chat" }],
  ]);
});

test("Copy link asks the daemon once, for a view link (the host's gesture gate allows one call per click)", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const client = shareClient("chat", async (op, params) => {
    calls.push([op, params]);
    return op === "link" ? { shareId: "v1", url: "https://room/g/v1#secret" } : {};
  });
  await client.viewerLink(shareView([]));
  expect(calls).toEqual([["link", { role: "view", session: "chat" }]]);
});

test("team access reopens with its role and invite URL, never as a bearer link", () => {
  const team = { ...base, teamId: "team-a", role: "view" as const, inviteUrl: "https://room/i/team" };
  const teams = [{ id: "team-a", name: "Design" }];
  const view = shareView([team, { ...team, shareId: "old", state: "revoked" }], teams);
  expect(view.general).toBe("restricted");
  expect(view.links).toEqual([]);
  expect(view.teams).toEqual(teams);
  expect(view.teamShares).toEqual([team]);
});

test("restricting bearer access preserves team and named grants", async () => {
  const team: ChatShare = { ...base, shareId: "team", teamId: "team-a", role: "view" };
  const link: ChatShare = { ...base, shareId: "link", role: "view" };
  const calls: unknown[] = [];
  const client = shareClient("chat", async (op, params) => {
    if (op === "revoke") calls.push(params);
    return { shares: [team, { ...base, shareId: "named" }] };
  });
  await client.restrict(shareView([team, link]));
  expect(calls).toEqual([{ shareId: "link", session: "chat" }]);
});

test("team creation pins chat, team and role in one gesture operation and propagates decline", async () => {
  const calls: unknown[] = [];
  const client = shareClient("chat-a", async (op, params) => {
    calls.push([op, params]);
    throw new Error("declined");
  });
  await expect(client.team("team-a", "talk")).rejects.toThrow("declined");
  expect(calls).toEqual([["team", { teamId: "team-a", role: "talk", session: "chat-a" }]]);
});
