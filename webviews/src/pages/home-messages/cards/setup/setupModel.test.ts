import { describe, expect, test } from "bun:test";
import { cardStrings } from "../strings";
import { nextStep, setupProgress, setupSteps, type SetupState } from "./setupModel";

const strings = cardStrings(["en"]);

const fresh: SetupState = {
  agents: [
    { id: "claude", name: "Claude Code", state: "missing" },
    { id: "codex", name: "Codex", state: "missing" },
  ],
  account: { signedIn: false },
  cli: "missing",
  classic: null,
};

describe("setupSteps", () => {
  test("a fresh Mac: agents, account, command line; the next row installs the first agent", () => {
    const steps = setupSteps(fresh, strings);
    expect(steps.map((step) => step.id)).toEqual(["agents", "account", "cli"]);
    expect(steps[0]?.detail).toBe("Claude Code, Codex");
    expect(nextStep(steps)?.action?.run).toEqual({ kind: "installAgent", id: "claude" });
    expect(setupProgress(steps)).toEqual({ done: 0, total: 3 });
  });

  test("classic's session leads, with Import and Not Now, until answered", () => {
    const state: SetupState = { ...fresh, classic: { workspaces: 27, saved: "1 minute ago" } };
    const steps = setupSteps(state, strings);
    expect(steps[0]?.id).toBe("classic");
    expect(steps[0]?.detail).toBe("27 workspaces, saved 1 minute ago");
    expect(steps[0]?.action?.run).toEqual({ kind: "importClassic" });
    expect(steps[0]?.secondary?.run).toEqual({ kind: "declineClassic" });
    const answered = setupSteps({ ...state, classic: { ...state.classic!, answered: "declined" } }, strings);
    expect(answered[0]?.done).toBe(true);
    expect(answered[0]?.action).toBeUndefined();
  });

  test("a signed-out agent offers its sign-in over installing another; a signed-in one finishes the row", () => {
    const signedOut = setupSteps(
      { ...fresh, agents: [fresh.agents[0]!, { id: "codex", name: "Codex", state: "signedOut" }] },
      strings,
    );
    expect(signedOut[0]?.action?.run).toEqual({ kind: "signInAgent", id: "codex" });
    const ready = setupSteps(
      { ...fresh, agents: [{ id: "claude", name: "Claude Code", state: "signedIn" }, fresh.agents[1]!] },
      strings,
    );
    expect(ready[0]).toMatchObject({ done: true, detail: "Claude Code is ready" });
    expect(nextStep(ready)?.id).toBe("account");
  });

  test("an install in flight is busy; another app's cmux offers Replace", () => {
    const steps = setupSteps(
      { ...fresh, agents: [{ id: "claude", name: "Claude Code", state: "installing" }], cli: "other" },
      strings,
    );
    expect(steps[0]?.busy).toBe(true);
    expect(steps[2]?.action?.label).toBe("Replace");
  });

  test("every row done: no next step", () => {
    const steps = setupSteps(
      {
        agents: [{ id: "claude", name: "Claude Code", state: "signedIn" }],
        account: { signedIn: true, email: "you@example.com" },
        cli: "installed",
        classic: null,
      },
      strings,
    );
    expect(nextStep(steps)).toBeUndefined();
    expect(setupProgress(steps)).toEqual({ done: 3, total: 3 });
  });
});
