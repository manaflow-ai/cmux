import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { makeBillingCompleteHandler } from "../app/api/billing/complete/route";
import { selectPurchasedTeam as selectPurchasedTeamService } from "../services/teams/admin";
import type { TeamStackApp } from "../services/teams/stack";

let stripeConfigured = true;
let retrievedSession: Record<string, unknown>;
const retrieveSession = mock(async () => retrievedSession);
let recordCheckoutCompletionResult: unknown = {
  stackUserId: "user-1",
  subscriptionId: "sub_1",
};
const recordCheckoutCompletion = mock(async () => recordCheckoutCompletionResult);
const recordFoundersCheckoutCompletion = mock(async () => ({
  scope: "user" as const,
  stackUserId: "founder-user",
  subscriptionId: "founder-subscription",
}));

const selectPurchasedTeam = mock(async (_input: { readonly userId: string; readonly teamId: string }) => {});

const GET = makeBillingCompleteHandler({
  isConfigured: () => stripeConfigured,
  stripe: () =>
    ({
      checkout: {
        sessions: {
          retrieve: retrieveSession,
        },
      },
    }) as never,
  recordCheckoutCompletion: recordCheckoutCompletion as never,
  recordFoundersCheckoutCompletion: recordFoundersCheckoutCompletion as never,
  selectPurchasedTeam,
});

describe("billing complete route", () => {
  beforeEach(() => {
    stripeConfigured = true;
    retrievedSession = {
      id: "cs_123",
      payment_status: "paid",
      client_reference_id: "user-1",
      metadata: { app: "cmux", plan: "pro" },
      subscription: { id: "sub_1" },
      customer: { id: "cus_1" },
    };
    retrieveSession.mockClear();
    recordCheckoutCompletion.mockClear();
    recordFoundersCheckoutCompletion.mockClear();
    selectPurchasedTeam.mockClear();
    selectPurchasedTeam.mockImplementation(async () => {});
    recordCheckoutCompletionResult = {
      stackUserId: "user-1",
      subscriptionId: "sub_1",
    };
  });

  test("records paid sessions and redirects to success with the validated scheme", async () => {
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = "cmux-dev-local";
    const response = await GET(
      new NextRequest(
        "http://localhost:3777/api/billing/complete?session_id=cs_123&cmux_scheme=cmux-dev-local",
      ),
    );

    expect(retrieveSession).toHaveBeenCalledWith("cs_123", {
      expand: ["subscription", "customer"],
    });
    expect(recordCheckoutCompletion).toHaveBeenCalledWith({
      session: retrievedSession,
      subscription: retrievedSession.subscription,
      customer: retrievedSession.customer,
    });
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "http://localhost:3777/billing/success?session_id=cs_123&cmux_scheme=cmux-dev-local",
    );
  });

  test("a dashboard checkout returns to its page with a welcome for the plan", async () => {
    retrievedSession = { ...retrievedSession, metadata: { app: "cmux", plan: "max", returnTo: "/ja/dashboard/cloud" } };
    const response = await GET(new NextRequest("http://localhost:3777/api/billing/complete?session_id=cs_123"));
    expect(recordCheckoutCompletion).toHaveBeenCalled();
    expect(response.headers.get("location")).toBe("http://localhost:3777/ja/dashboard/cloud?welcome=max");
  });

  test("an invalid stored returnTo falls back to the success page", async () => {
    retrievedSession = { ...retrievedSession, metadata: { app: "cmux", plan: "pro", returnTo: "//evil.example/dashboard" } };
    const response = await GET(new NextRequest("http://localhost:3777/api/billing/complete?session_id=cs_123"));
    expect(response.headers.get("location")).toStartWith("http://localhost:3777/billing/success?");
  });

  test("uses the callback scheme trusted at checkout on a deployed completion host", async () => {
    retrievedSession = {
      id: "cs_123",
      payment_status: "paid",
      client_reference_id: "user-1",
      metadata: {
        app: "cmux",
        plan: "pro",
        nativeCallbackScheme: "cmux-dev-local",
      },
      subscription: { id: "sub_1" },
      customer: { id: "cus_1" },
    };
    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/complete?session_id=cs_123&cmux_scheme=cmux-dev-local",
      ),
    );

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/billing/success?session_id=cs_123&cmux_scheme=cmux-dev-local",
    );
  });

  test("redirects unpaid sessions to pending pricing state", async () => {
    retrievedSession = {
      id: "cs_123",
      payment_status: "unpaid",
      client_reference_id: "user-1",
      metadata: { app: "cmux", plan: "pro" },
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_123"),
    );

    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe("https://cmux.test/pricing?welcome=pending");
  });

  test("redirects paid Team sessions to dashboard billing after recording", async () => {
    retrievedSession = {
      id: "cs_team",
      payment_status: "paid",
      client_reference_id: "team-1",
      metadata: { app: "cmux", plan: "team", stackTeamId: "team-1" },
      subscription: { id: "sub_team" },
      customer: { id: "cus_team" },
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_team"),
    );

    expect(recordCheckoutCompletion).toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/teams/team-1/billing?welcome=team",
    );
  });

  // Cloud, its upgrade prompt and the VM gate all read the Stack-selected team.
  // Buying Team for a team that is not selected must not leave them on the old one.
  describe("selecting the purchased team", () => {
    const teamSession = (metadata: Record<string, string>) => ({
      id: "cs_team",
      payment_status: "paid",
      client_reference_id: "buyer-1",
      metadata: { app: "cmux", plan: "team", ...metadata },
      subscription: { id: "sub_team" },
      customer: { id: "cus_team" },
    });
    const complete = () => GET(new NextRequest("http://localhost:3777/api/billing/complete?session_id=cs_team"));

    test("a recorded Team purchase selects that team for the buyer", async () => {
      retrievedSession = teamSession({ stackTeamId: "team-paid", stackUserId: "buyer-1" });
      const response = await complete();
      expect(selectPurchasedTeam).toHaveBeenCalledTimes(1);
      expect(selectPurchasedTeam).toHaveBeenCalledWith({ userId: "buyer-1", teamId: "team-paid" });
      expect(response.headers.get("location")).toBe("http://localhost:3777/dashboard/teams/team-paid/billing?welcome=team");
    });

    test("a failed selection still lands the paid buyer on the team's billing page", async () => {
      retrievedSession = teamSession({ stackTeamId: "team-paid", stackUserId: "buyer-1" });
      selectPurchasedTeam.mockImplementation(async () => {
        throw new Error("Stack Auth unavailable");
      });
      const response = await complete();
      expect(selectPurchasedTeam).toHaveBeenCalledTimes(1);
      expect(response.headers.get("location")).toBe("http://localhost:3777/dashboard/teams/team-paid/billing?welcome=team");
    });

    const unselectable: readonly (readonly [string, Record<string, string>])[] = [
      ["a personal purchase", { app: "cmux", plan: "pro", stackUserId: "buyer-1" }],
      ["a Team session without a team id", { app: "cmux", plan: "team", stackUserId: "buyer-1" }],
      ["a Team session without a buyer", { app: "cmux", plan: "team", stackTeamId: "team-paid" }],
    ];
    for (const [name, metadata] of unselectable) {
      test(`${name} selects nothing`, async () => {
        retrievedSession = { ...teamSession({}), metadata };
        await complete();
        expect(selectPurchasedTeam).not.toHaveBeenCalled();
      });
    }

    test("an unpaid Team session selects nothing", async () => {
      retrievedSession = { ...teamSession({ stackTeamId: "team-paid", stackUserId: "buyer-1" }), payment_status: "unpaid" };
      await complete();
      expect(selectPurchasedTeam).not.toHaveBeenCalled();
    });

    test("a Team session skipped for account deletion selects nothing", async () => {
      retrievedSession = teamSession({ stackTeamId: "team-paid", stackUserId: "buyer-1" });
      recordCheckoutCompletionResult = { skipped: "account_deletion_in_progress", stackUserId: "buyer-1", subscriptionId: "sub_team" };
      await complete();
      expect(selectPurchasedTeam).not.toHaveBeenCalled();
    });
  });

  test("records paid Founder sessions through the Founder completion path", async () => {
    retrievedSession = {
      id: "cs_founder",
      payment_status: "paid",
      client_reference_id: null,
      metadata: { founders_edition: "true" },
      subscription: null,
      customer: { id: "cus_founder" },
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_founder"),
    );

    expect(recordFoundersCheckoutCompletion).toHaveBeenCalledWith({
      session: retrievedSession,
      subscription: null,
      customer: retrievedSession.customer,
    });
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/billing/success?session_id=cs_founder&cmux_scheme=cmux",
    );
  });

  test("rejects conflicting Team and Founder metadata before provisioning", async () => {
    retrievedSession = {
      id: "cs_conflicting_scope",
      payment_status: "paid",
      client_reference_id: "team-1",
      metadata: {
        founders_edition: "true",
        app: "cmux",
        plan: "team",
        stackTeamId: "team-1",
      },
      subscription: {
        id: "sub_conflicting_scope",
        metadata: {
          founders_edition: "true",
          app: "cmux",
          plan: "team",
          stackTeamId: "team-1",
        },
      },
      customer: { id: "cus_conflicting_scope" },
    };

    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/complete?session_id=cs_conflicting_scope",
      ),
    );

    expect(recordFoundersCheckoutCompletion).not.toHaveBeenCalled();
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=error",
    );
  });

  test("does not redirect to success when checkout is cancelled for account deletion", async () => {
    recordCheckoutCompletionResult = {
      skipped: "account_deletion_in_progress",
      stackUserId: "user-1",
      subscriptionId: "sub_1",
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_123"),
    );

    expect(recordCheckoutCompletion).toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=account_deletion",
    );
  });

  test("rejects foreign paid sessions without recording them", async () => {
    retrievedSession = {
      id: "cs_foreign",
      payment_status: "paid",
      client_reference_id: "foreign-user",
      metadata: { app: "other", plan: "pro" },
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_foreign"),
    );

    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe("https://cmux.test/pricing?billing=error");
  });

  test("rejects a foreign session when its expanded subscription says Founder", async () => {
    retrievedSession = {
      id: "cs_foreign_founder",
      payment_status: "paid",
      client_reference_id: "foreign-user",
      metadata: { app: "other", plan: "pro" },
      subscription: {
        id: "sub_foreign_founder",
        metadata: { app: "cmux", founders_edition: "true" },
      },
      customer: { id: "cus_foreign_founder" },
    };

    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/complete?session_id=cs_foreign_founder",
      ),
    );

    expect(recordFoundersCheckoutCompletion).not.toHaveBeenCalled();
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe("https://cmux.test/pricing?billing=error");
  });
});

describe("selectPurchasedTeam", () => {
  test("persists the purchased team as the buyer's selected team", async () => {
    const update = mock(async (_update: { selectedTeamId?: string | null }) => {});
    const getUser = mock(async (_userId: string) => ({ update }));
    await selectPurchasedTeamService(
      { userId: "buyer-1", teamId: "team-paid" },
      { stack: { getUser } as unknown as TeamStackApp },
    );
    expect(getUser).toHaveBeenCalledWith("buyer-1");
    expect(update).toHaveBeenCalledWith({ selectedTeamId: "team-paid" });
  });

  test("surfaces a Stack refusal to its caller", async () => {
    const update = mock(async (_update: { selectedTeamId?: string | null }) => {
      throw new Error("not a member");
    });
    const stack = { getUser: async () => ({ update }) } as unknown as TeamStackApp;
    await expect(selectPurchasedTeamService({ userId: "buyer-1", teamId: "team-gone" }, { stack })).rejects.toThrow("not a member");
  });
});
