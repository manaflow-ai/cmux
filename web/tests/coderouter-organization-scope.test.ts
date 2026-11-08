import { describe, expect, test } from "bun:test";
import {
  coderouterOrganizationCookie,
  coderouterOrganizationFromCookieHeader,
} from "../services/coderouter/organizationScope";

describe("CodeRouter organization scope", () => {
  test("reads only a valid dedicated organization cookie", () => {
    expect(
      coderouterOrganizationFromCookieHeader(
        "other=value; cmux_coderouter_organization=%5B%22user-1%22%2C%22team%2Ftwo%22%5D",
        "user-1",
      ),
    ).toBe("team/two");
    expect(
      coderouterOrganizationFromCookieHeader(
        "cmux_coderouter_organization=%5B%22other-user%22%2C%22team-two%22%5D",
        "user-1",
      ),
    ).toBeNull();
    expect(coderouterOrganizationFromCookieHeader(null, "user-1")).toBeNull();
  });

  test("writes a bounded secure same-site cookie", () => {
    expect(coderouterOrganizationCookie("user-1", "team/two")).toBe(
      "cmux_coderouter_organization=%5B%22user-1%22%2C%22team%2Ftwo%22%5D; Path=/; Max-Age=31536000; SameSite=Lax; Secure",
    );
    expect(coderouterOrganizationCookie("user-1", " team ")).toBeNull();
  });
});
