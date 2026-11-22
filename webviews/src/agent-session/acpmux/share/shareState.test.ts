// l10n-allow-file: test fixtures.
import { afterEach, expect, test } from "bun:test";
import { forgetShareLinks, isAccount, shareClient, shareView, type ChatShare } from "./shareState";

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
  expect(shareView([])).toEqual({ people: [], general: "restricted", links: [], inviteUrl: null, guestsNow: 0 });
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
  expect(view.people).toEqual([{ account: "ana@example.com", role: "talk", joined: true }]);
  expect(view.inviteUrl).toBe("https://room/i/b");
  expect(view.general).toBe("restricted");
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
