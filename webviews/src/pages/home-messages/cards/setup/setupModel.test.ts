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

  test("chats found on this Mac: a chat history row after the agents, with Import and Not Now, until done", () => {
    const steps = setupSteps({ ...fresh, history: { done: false } }, strings);
    expect(steps.map((step) => step.id)).toEqual(["agents", "history", "account", "cli"]);
    expect(steps[1]).toMatchObject({ title: "Your chat history", detail: "Chats from Claude Code and Codex" });
    expect(steps[1]?.action?.run).toEqual({ kind: "importHistory" });
    expect(steps[1]?.secondary?.run).toEqual({ kind: "declineHistory" });
    const done = setupSteps({ ...fresh, history: { done: true } }, strings)[1]!;
    expect(done.done).toBe(true);
    expect([done.action, done.secondary]).toEqual([undefined, undefined]);
    // None found: no row.
    expect(setupSteps({ ...fresh, history: null }, strings).map((step) => step.id)).not.toContain("history");
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

  test("a cmux that is no cmux app's, or cmux run from its disk image: a line and no button, never Replace", () => {
    for (const [cli, detail] of [
      ["foreign", "Another cmux command is on your PATH"],
      ["fromImage", "Open cmux from Applications to install it"],
    ] as const) {
      const row = setupSteps({ ...fresh, cli }, strings).find((step) => step.id === "cli")!;
      expect(row).toMatchObject({ done: false, detail });
      expect(row.action).toBeUndefined();
    }
  });

  test("a command line install in flight: a spinner and no button, so a second click starts nothing", () => {
    const row = setupSteps({ ...fresh, cli: "installing" }, strings).find((step) => step.id === "cli")!;
    expect(row).toMatchObject({ done: false, busy: true });
    expect(row.action).toBeUndefined();
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
