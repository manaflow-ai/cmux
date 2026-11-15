import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { TeamTag, activeTeamFromReply, teamIconName, withTeam } from "./TeamTag";

describe("TeamTag", () => {
  test("reads the app's team, and nothing that names none", () => {
    expect(activeTeamFromReply({ name: " cmux ", personal: false })).toEqual({ name: "cmux", personal: false });
    expect(activeTeamFromReply({ name: "Personal", personal: true })).toEqual({ name: "Personal", personal: true });
    expect(activeTeamFromReply({ name: "  " })).toBeUndefined();
    expect(activeTeamFromReply({ personal: true })).toBeUndefined();
    expect(activeTeamFromReply(undefined)).toBeUndefined();
  });

  test("a team the account's list no longer has is never named: the person's own team instead", () => {
    const personal = { id: "t0", name: "Personal", personal: true };
    const shared = { id: "t1", name: "cmux", personal: false };
    expect(activeTeamFromReply({ name: "cmux", personal: false }, [personal, shared])).toEqual({
      name: "cmux",
      personal: false,
    });
    expect(activeTeamFromReply({ name: "gone", personal: false }, [personal, shared])).toEqual({
      name: "Personal",
      personal: true,
    });
    expect(activeTeamFromReply({ name: "gone", personal: false }, [shared])).toBeUndefined();
    // By id where the app names one: a removed team that shares a listed team's name is still gone.
    expect(activeTeamFromReply({ id: "t9", name: "cmux", personal: false }, [personal, shared])).toEqual({
      name: "Personal",
      personal: true,
    });
    expect(activeTeamFromReply({ id: "t1", name: "cmux", personal: false }, [personal, shared])).toEqual({
      name: "cmux",
      personal: false,
    });
    // No list in the reply (an older app): the team as named.
    expect(activeTeamFromReply({ name: "gone", personal: false })).toEqual({ name: "gone", personal: false });
  });

  test("a person icon for the person's own team, people for a shared one", () => {
    expect(teamIconName({ name: "Personal", personal: true })).toBe("account");
    expect(teamIconName({ name: "cmux", personal: false })).toBe("team");
  });

  test("shows the team's name", () => {
    const html = renderToStaticMarkup(<TeamTag team={{ name: "cmux", personal: false }} />);
    expect(html).toContain("acpmux-team-tag");
    expect(html).toContain(">cmux<");
    expect(html).not.toContain("data-personal");
    expect(renderToStaticMarkup(<TeamTag team={{ name: "Personal", personal: true }} />)).toContain("data-personal");
  });
});

describe("a Cloud pick's accessible name", () => {
  test("names the team in every layout's label and tooltip, and nothing without one", () => {
    expect(withTeam("Cloud", { name: "cmux", personal: false })).toBe("Cloud · cmux");
    expect(withTeam("Sandboxed", { name: "Personal", personal: true })).toBe("Sandboxed · Personal");
    expect(withTeam("Cloud", undefined)).toBe("Cloud");
  });
});
