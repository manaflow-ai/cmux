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

  // 2026-11-05 22:26 local: the save time the row names, in the page's own language.
  const savedAt = new Date(2026, 10, 5, 22, 26).getTime();
  const saved = new Intl.DateTimeFormat("en", { dateStyle: "medium", timeStyle: "short" }).format(savedAt);

  test("classic's session leads, naming the app and its save, with Import and Skip, until answered", () => {
    const state: SetupState = { ...fresh, classic: { workspaces: 27, app: "cmux NIGHTLY", savedAt } };
    const steps = setupSteps(state, strings);
    expect(steps[0]?.id).toBe("classic");
    expect(steps[0]?.title).toBe("cmux Classic");
    expect(steps[0]?.detail).toBe(`27 workspaces from cmux NIGHTLY, saved ${saved}`);
    expect(steps[0]?.note).toBeUndefined();
    expect(steps[0]?.action?.run).toEqual({ kind: "importClassic" });
    expect(steps[0]?.secondary).toEqual({ label: "Skip", run: { kind: "declineClassic" } });
    const declined = setupSteps({ ...state, classic: { ...state.classic!, answered: "declined" } }, strings);
    expect(declined[0]?.done).toBe(true);
    expect(declined[0]?.action).toBeUndefined();
    expect(declined[0]?.detail).toBe("Not imported: Settings › Import brings them any time");
    const imported = setupSteps({ ...state, classic: { ...state.classic!, answered: "imported" } }, strings);
    expect([imported[0]?.done, imported[0]?.detail]).toEqual([true, "Imported"]);
  });

  test("a classic app still open, and an import that reconnects or resumes, say so before Import", () => {
    const open = setupSteps({ ...fresh, classic: { workspaces: 3, app: "cmux", savedAt, running: true, resumes: true } }, strings);
    expect(open[0]?.detail).toBe(`cmux is still open: this is its autosave from ${saved}. Quit it first to bring its latest state.`);
    expect(open[0]?.note).toContain("connects to saved SSH hosts");
    const answered = setupSteps(
      { ...fresh, classic: { workspaces: 3, app: "cmux", savedAt, resumes: true, answered: "imported" } },
      strings,
    );
    expect(answered[0]?.note).toBeUndefined();
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

  test("a login opened here that cannot be read: the person confirms it or signs in again; the row stays open", () => {
    const steps = setupSteps(
      { ...fresh, agents: [{ id: "claude", name: "Claude Code", state: "unverified" }, fresh.agents[1]!] },
      strings,
    );
    expect(steps[0]).toMatchObject({ done: false, detail: "Finish signing in to Claude Code in its terminal tab" });
    expect(steps[0]?.action).toEqual({ label: "I’m Signed In", run: { kind: "confirmAgent", id: "claude" } });
    expect(steps[0]?.secondary).toEqual({ label: "Sign In Again", run: { kind: "signInAgent", id: "claude" } });
    expect(steps[0]?.tertiary).toEqual({ label: "Install Codex", run: { kind: "installAgent", id: "codex" } });
    expect(nextStep(steps)?.id).toBe("agents");
  });

  test("an unverified agent with no other agent shows no third button", () => {
    const [row] = setupSteps(
      { ...fresh, agents: [{ id: "claude", name: "Claude Code", state: "unverified" }] },
      strings,
    );
    expect(row?.secondary?.run).toEqual({ kind: "signInAgent", id: "claude" });
    expect(row?.tertiary).toBeUndefined();
  });

  test("every agent has a button: Codex stays reachable while Claude Code installs or after it fails", () => {
    const freshRow = setupSteps(fresh, strings)[0]!;
    expect(freshRow.action?.run).toEqual({ kind: "installAgent", id: "claude" });
    expect(freshRow.secondary).toEqual({ label: "Install Codex", run: { kind: "installAgent", id: "codex" } });
    for (const state of ["installing", "failed"] as const) {
      const row = setupSteps({ ...fresh, agents: [{ ...fresh.agents[0]!, state }, fresh.agents[1]!] }, strings)[0]!;
      expect(row.secondary?.run).toEqual({ kind: "installAgent", id: "codex" });
      // Installs run one at a time: while Claude Code installs, Codex's waits, greyed, and the row says so.
      expect(row.secondary?.disabled === true).toBe(state === "installing");
      if (state === "installing") expect(row.detail).toBe("Codex installs after Claude Code");
    }
    const both = setupSteps(
      { ...fresh, agents: fresh.agents.map((agent) => ({ ...agent, state: "installing" as const })) },
      strings,
    )[0]!;
    expect(both.busy).toBe(true);
    expect([both.action, both.secondary]).toEqual([undefined, undefined]);
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
