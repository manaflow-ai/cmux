import { describe, expect, test } from "bun:test";
import { parseMaxUses } from "../dashboard-app/screens/teams/team-logic";
import { createLinkBody } from "../services/teams/schemas";

describe("invite link use cap", () => {
  test("the form accepts exactly the values the API accepts", () => {
    for (const maxUses of [1, 1000, 1001, 10_000]) {
      const client = parseMaxUses(String(maxUses)).ok;
      const server = createLinkBody.safeParse({ expiresInDays: null, maxUses }).success;
      expect({ maxUses, client }).toEqual({ maxUses, client: server });
    }
  });
});
