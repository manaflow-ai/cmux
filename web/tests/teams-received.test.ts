import { describe, expect, test } from "bun:test";
import { requireTeamAccess } from "../services/teams/access";
import { TeamServiceUnavailableError } from "../services/teams/errors";
import { buildTeamInviteEmail } from "../services/teams/inviteEmail";
import { inviteTeamMembers } from "../services/teams/invitations";
import { previewTeamInviteLink, redeemTeamInviteLink } from "../services/teams/links";
import {
  acceptReceivedInvitation,
  declineReceivedInvitation,
  listReceivedInvitations,
} from "../services/teams/received";
import {
  ADMIN_ID,
  MemoryInviteMailer,
  MemoryInviteStore,
  MemoryTeamSeatSync,
  OUTSIDER_ID,
  standardTeam,
  TEAM_ID,
} from "./teams-fixture";

const acceptUrl = (token: string) => `https://cmux.com/en/join/${token}`;

async function invited(email = "outsider@example.com", role: "admin" | "member" = "member") {
  const stack = standardTeam();
  stack.setVerifiedEmails(OUTSIDER_ID, [email]);
  const store = new MemoryInviteStore();
  const mailer = new MemoryInviteMailer();
  const seats = new MemoryTeamSeatSync();
  const access = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
  if (!access.ok) throw new Error("access refused");
  const { invitations } = await inviteTeamMembers(access.access, { emails: [email], role, acceptUrl }, { store, mailer });
  const token = mailer.sent[0]!.acceptUrl.split("/").pop()!;
  return { stack, store, mailer, seats, invitation: invitations[0]!, token, deps: { store, stack: stack.app(), seats } };
}

describe("received invitations", () => {
  test("lists pending invitations for the user's verified emails with team and inviter", async () => {
    const { deps, invitation } = await invited();
    const received = await listReceivedInvitations(OUTSIDER_ID, deps);
    expect(received).toEqual([{
      id: invitation.id,
      teamId: TEAM_ID,
      teamName: "Acme",
      email: "outsider@example.com",
      role: "member",
      invitedBy: "Name aaaa",
      expiresAt: invitation.expiresAt,
    }]);
    const other = standardTeam();
    expect(await listReceivedInvitations(ADMIN_ID, { ...deps, stack: other.app() })).toEqual([]);
  });

  test("accepting by id joins the team, applies the role, marks the row and selects the team", async () => {
    const { stack, store, seats, deps, invitation } = await invited("outsider@example.com", "admin");
    const result = await acceptReceivedInvitation(OUTSIDER_ID, invitation.id, deps);
    expect(result).toEqual({ teamId: TEAM_ID, role: "admin" });
    expect(stack.teams.get(TEAM_ID)!.members.has(OUTSIDER_ID)).toBe(true);
    expect(stack.grantsOf(TEAM_ID, OUTSIDER_ID).has("team_admin")).toBe(true);
    expect(stack.users.get(OUTSIDER_ID)!.selectedTeamId).toBe(TEAM_ID);
    expect(store.emailInvitations[0]!.acceptedByUserId).toBe(OUTSIDER_ID);
    expect(seats.changed).toEqual([TEAM_ID]);
    expect(await listReceivedInvitations(OUTSIDER_ID, deps)).toEqual([]);
    await expect(acceptReceivedInvitation(OUTSIDER_ID, invitation.id, deps)).rejects.toMatchObject({ code: "invitation_invalid" });
  });

  test("a user whose verified emails do not include the address gets email_mismatch", async () => {
    const { stack, deps, invitation } = await invited();
    stack.setVerifiedEmails(OUTSIDER_ID, ["someone@else.example"]);
    await expect(acceptReceivedInvitation(OUTSIDER_ID, invitation.id, deps)).rejects.toMatchObject({ code: "email_mismatch", status: 409 });
    expect(stack.teams.get(TEAM_ID)!.members.has(OUTSIDER_ID)).toBe(false);
  });

  test("a Stack failure while joining leaves the invitation pending", async () => {
    const { stack, deps, invitation } = await invited();
    stack.failAddUser = new Error("stack down");
    await expect(acceptReceivedInvitation(OUTSIDER_ID, invitation.id, deps)).rejects.toBeInstanceOf(TeamServiceUnavailableError);
    expect(await listReceivedInvitations(OUTSIDER_ID, deps)).toHaveLength(1);
  }, 15_000);

  test("declining hides the invitation for both sides", async () => {
    const { deps, invitation, store } = await invited();
    await declineReceivedInvitation(OUTSIDER_ID, invitation.id, deps);
    expect(await listReceivedInvitations(OUTSIDER_ID, deps)).toEqual([]);
    expect(await store.listPendingEmailInvitations(TEAM_ID)).toEqual([]);
  });

  test("the emailed token joins through the link page and still checks the email", async () => {
    const { stack, deps, token } = await invited();
    expect(await previewTeamInviteLink(OUTSIDER_ID, token, deps)).toEqual({ teamDisplayName: "Acme", alreadyMember: false });
    stack.setVerifiedEmails(OUTSIDER_ID, ["someone@else.example"]);
    await expect(redeemTeamInviteLink(OUTSIDER_ID, token, deps)).rejects.toMatchObject({ code: "email_mismatch" });
    stack.setVerifiedEmails(OUTSIDER_ID, ["outsider@example.com"]);
    expect(await redeemTeamInviteLink(OUTSIDER_ID, token, deps)).toEqual({ teamId: TEAM_ID });
    // A used token is gone; the same string no longer resolves as anything.
    await expect(redeemTeamInviteLink(OUTSIDER_ID, token, deps)).rejects.toMatchObject({ code: "link_invalid" });
  });

  test("a personal-plan team with no free seat refuses the accept", async () => {
    const { stack, deps, invitation } = await invited();
    stack.teams.get(TEAM_ID)!.metadata = { cmuxPlan: "pro" };
    stack.addUser({ id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd" }).addMember(TEAM_ID, "dddddddd-dddd-4ddd-8ddd-dddddddddddd", ["team_member"]);
    await expect(acceptReceivedInvitation(OUTSIDER_ID, invitation.id, deps)).rejects.toMatchObject({ code: "seat_limit" });
  });
});

describe("invite email", () => {
  test("names the inviter and team, links once, and tells a new user how to install cmux", () => {
    const email = buildTeamInviteEmail({
      from: "cmux <invites@cmux.com>",
      to: "new@example.com",
      teamName: "Acme <Labs>",
      inviterName: "Ada",
      role: "admin",
      acceptUrl: "https://cmux.com/en/join/tok",
      expiresAt: new Date("2026-10-07T00:00:00Z"),
    });
    expect(email.subject).toBe("Ada invited you to Acme <Labs> on cmux");
    expect(email.text).toContain("Ada invited you to Acme <Labs> on cmux as an admin.");
    expect(email.text).toContain("Accept: https://cmux.com/en/join/tok");
    expect(email.text).toContain("Download it for Mac at https://cmux.com/download");
    expect(email.text).toContain("sign in with this address (new@example.com)");
    expect(email.text).toContain("expires on 2026-10-07");
    expect(email.html).toContain("Acme &lt;Labs&gt;");
    expect(email.html.match(/href=/g)).toHaveLength(2);
    expect(email.headers["Auto-Submitted"]).toBe("auto-generated");
  });

  test("an unknown inviter reads as a teammate", () => {
    const email = buildTeamInviteEmail({
      from: "cmux <invites@cmux.com>",
      to: "new@example.com",
      teamName: "Acme",
      inviterName: null,
      role: "member",
      acceptUrl: "https://cmux.com/en/join/tok",
      expiresAt: new Date("2026-10-07T00:00:00Z"),
    });
    expect(email.subject).toBe("A teammate invited you to Acme on cmux");
    expect(email.text).not.toContain("as an admin");
  });
});
