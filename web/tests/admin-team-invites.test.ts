import { describe, expect, test } from "bun:test";
import { AdminTeamNotFoundError } from "../services/admin/proGrants";
import { inviteTeamMembersAsOperator, OPERATOR_INVITER_NAME } from "../services/admin/teamInvites";
import {
  MemoryInviteMailer,
  MemoryInviteStore,
  MEMBER_ID,
  standardTeam,
  TEAM_ID,
} from "./teams-fixture";

// A cmux operator (cmux-admin) invites people into a customer team it is not
// a member of, as admins or members, through the team's own invitation store,
// email and accept flow.

const OPERATOR_ID = "99999999-9999-4999-8999-999999999999";
const acceptUrl = (token: string) => `https://cmux.test/join/${token}`;

describe("operator team invitations", () => {
  test("invites with the chosen role, records the operator, and names cmux as the sender", async () => {
    const stack = standardTeam();
    const store = new MemoryInviteStore();
    const mailer = new MemoryInviteMailer();

    const result = await inviteTeamMembersAsOperator({
      teamId: TEAM_ID,
      emails: ["David@Customer.example ", "andrii@customer.example"],
      role: "admin",
      admin: { id: OPERATOR_ID },
      acceptUrl,
      stack: stack.app(),
      dependencies: { store, mailer },
    });

    expect(result.failed).toEqual([]);
    expect(result.invitations.map((invitation) => [invitation.email, invitation.role])).toEqual([
      ["david@customer.example", "admin"],
      ["andrii@customer.example", "admin"],
    ]);
    expect(mailer.sent.map((mail) => [mail.to, mail.role, mail.inviterName])).toEqual([
      ["david@customer.example", "admin", OPERATOR_INVITER_NAME],
      ["andrii@customer.example", "admin", OPERATOR_INVITER_NAME],
    ]);
    expect(mailer.sent.every((mail) => mail.acceptUrl.startsWith("https://cmux.test/join/"))).toBe(true);
    const pending = await store.listPendingEmailInvitations(TEAM_ID);
    expect(pending.map((row) => [row.email, row.role, row.invitedByUserId]).sort()).toEqual([
      ["andrii@customer.example", "admin", OPERATOR_ID],
      ["david@customer.example", "admin", OPERATOR_ID],
    ]);
  });

  test("an existing member is reported, not re-invited", async () => {
    const stack = standardTeam();
    const mailer = new MemoryInviteMailer();
    const memberEmail = `${MEMBER_ID.slice(0, 4)}@example.com`;

    const result = await inviteTeamMembersAsOperator({
      teamId: TEAM_ID,
      emails: [memberEmail],
      role: "member",
      admin: { id: OPERATOR_ID },
      acceptUrl,
      stack: stack.app(),
      dependencies: { store: new MemoryInviteStore(), mailer },
    });

    expect(result.failed).toEqual([{ email: memberEmail, code: "already_member" }]);
    expect(mailer.sent).toEqual([]);
  });

  test("an unknown team is not found and nothing is sent", async () => {
    const stack = standardTeam();
    const mailer = new MemoryInviteMailer();

    await expect(inviteTeamMembersAsOperator({
      teamId: "22222222-2222-4222-8222-222222222222",
      emails: ["someone@customer.example"],
      role: "member",
      admin: { id: OPERATOR_ID },
      acceptUrl,
      stack: stack.app(),
      dependencies: { store: new MemoryInviteStore(), mailer },
    })).rejects.toBeInstanceOf(AdminTeamNotFoundError);
    expect(mailer.sent).toEqual([]);
  });
});
