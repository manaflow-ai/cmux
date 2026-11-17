import { describe, expect, it } from "bun:test";
import { parseContactsAnswer, parseGroupInfoAnswer, parseRequests } from "./wire";

describe("sheets wire parsers", () => {
  it("reads requests and drops entries without a conversation or inviter", () => {
    const requests = parseRequests({
      requests: [
        { conversation: "c1", inviter: "Ada", isGroup: true, title: "Launch", preview: "hi", trusted: true },
        { conversation: "c2", inviter: "Ben" },
        { inviter: "Nobody" },
        { conversation: "c3" },
        "junk",
      ],
    });
    expect(requests).toEqual([
      { conversation: "c1", inviter: "Ada", isGroup: true, title: "Launch", preview: "hi", trusted: true },
      { conversation: "c2", inviter: "Ben", isGroup: false, preview: "", trusted: false },
    ]);
  });

  it("reads a missing or malformed answer as empty", () => {
    expect(parseRequests(undefined)).toEqual([]);
    expect(parseRequests({ requests: "no" })).toEqual([]);
    expect(parseContactsAnswer(null)).toEqual({ contacts: [], inviteTeam: null, pendingInvites: [] });
    expect(parseGroupInfoAnswer({})).toBeUndefined();
    expect(parseGroupInfoAnswer({ info: { title: "no id" } })).toBeUndefined();
  });

  it("reads contacts, keeping only known sources, and a blank team as none", () => {
    expect(
      parseContactsAnswer({
        contacts: [
          { id: "p1", name: "Ada", source: "team" },
          { id: "chief", name: "Chief", source: "agent" },
          { id: "p2", name: "Eve", source: "stranger" },
          { name: "No id", source: "team" },
        ],
        inviteTeam: "  ",
        pendingInvites: ["a@example.com", 3, ""],
      }),
    ).toEqual({
      contacts: [
        { id: "p1", name: "Ada", source: "team" },
        { id: "chief", name: "Chief", source: "agent" },
      ],
      inviteTeam: null,
      pendingInvites: ["a@example.com"],
    });
    expect(parseContactsAnswer({ contacts: [], inviteTeam: "Acme" }).inviteTeam).toBe("Acme");
  });

  it("reads group info with its members and optional fields", () => {
    const answer = parseGroupInfoAnswer({
      info: {
        conversation: "g1",
        isGroup: true,
        title: "",
        displayTitle: "Ada, Ben",
        members: [
          { id: "me", name: "Taylor", isMe: true, role: "owner" },
          { id: "ada", name: "Ada", role: "superuser", isInvited: true },
          { name: "no id" },
        ],
        canMute: true,
        muted: false,
        memberCount: 5000,
        chiefReplies: "mentions",
        canRename: false,
      },
      addable: [{ id: "cleo", name: "Cleo", source: "connection" }],
    });
    expect(answer).toEqual({
      info: {
        conversation: "g1",
        isGroup: true,
        title: "",
        displayTitle: "Ada, Ben",
        members: [
          { id: "me", name: "Taylor", isMe: true, isAgent: false, isInvited: false, role: "owner" },
          { id: "ada", name: "Ada", isMe: false, isAgent: false, isInvited: true },
        ],
        canMute: true,
        muted: false,
        memberCount: 5000,
        chiefReplies: "mentions",
        canRename: false,
      },
      addable: [{ id: "cleo", name: "Cleo", source: "connection" }],
    });
  });

  it("drops an unknown reply policy and a bad member count", () => {
    const answer = parseGroupInfoAnswer({
      info: { conversation: "g", isGroup: false, title: "T", chiefReplies: "never", memberCount: -1 },
    });
    expect(answer?.info.chiefReplies).toBeUndefined();
    expect(answer?.info.memberCount).toBeUndefined();
    expect(answer?.info.displayTitle).toBe("T");
  });
});
