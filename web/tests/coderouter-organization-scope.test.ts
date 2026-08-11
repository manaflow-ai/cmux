import { describe, expect, test } from "bun:test";
import {
  coderouterOrganizationCookie,
  coderouterOrganizationFromCookieHeader,
} from "../services/coderouter/organizationScope";

describe("CodeRouter organization scope", () => {
  test("reads only a valid dedicated organization cookie", () => {
    expect(
      coderouterOrganizationFromCookieHeader(
        "other=value; cmux_coderouter_organization=team%2Ftwo",
      ),
    ).toBe("team/two");
    expect(
      coderouterOrganizationFromCookieHeader(
        "cmux_coderouter_organization=%20team-two%20",
      ),
    ).toBeNull();
    expect(coderouterOrganizationFromCookieHeader(null)).toBeNull();
  });

  test("writes a bounded secure same-site cookie", () => {
    expect(coderouterOrganizationCookie("team/two")).toBe(
      "cmux_coderouter_organization=team%2Ftwo; Path=/; Max-Age=31536000; SameSite=Lax; Secure",
    );
    expect(coderouterOrganizationCookie(" team ")).toBeNull();
  });
});
