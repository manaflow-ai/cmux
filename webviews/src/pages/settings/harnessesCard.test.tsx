// Agents > Harnesses (cx-mg91): the card lists acpmux's harnesses from the host, follows a change
// live, reads again when it opens, and its buttons send the host's terminal gestures (Sign In and
// Check run `acpmux harness login <id>` in a terminal tab; the host checks the id).
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="harnesses"]');
const ids = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-harness]")].map((row) => row.dataset.harness);

test("owner job receipts stay pending until a terminal exit; a lost reply blocks another update, an unknown exit does not", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const base = page.provider.harnesses;
  const show = async (state: string, extra = {}) => {
    await act(async () =>
      page.provider.setHarnesses({
        ...base,
        jobs: [
          {
            machine: "machine_original",
            session: "session_original",
            cli: "codex",
            profiles: ["codex"],
            terminal: "term_original",
            state,
            ...extra,
          },
        ],
      } as typeof base),
    );
    await settle();
  };
  await show("created");
  let job = card(page.container)!.querySelector<HTMLElement>("[data-agent-update-job]");
  expect(job?.dataset.agentUpdateJob).toBe("created");
  expect(job?.textContent).toContain("Update terminal created");
  expect(
    card(page.container)!.querySelector<HTMLButtonElement>('[data-harness="codex"] [data-harness-action="update"]')
      ?.disabled,
  ).toBe(true);
  await show("pending");
  job = card(page.container)!.querySelector<HTMLElement>("[data-agent-update-job]");
  expect(job?.textContent).toContain("Waiting for update to finish");
  expect(
    card(page.container)!.querySelector<HTMLButtonElement>(
      '[data-harness-update-card="codex"] [data-harness-action="updateCard"]',
    )?.disabled,
  ).toBe(true);
  await show("exited", { exit_code: 23 });
  job = card(page.container)!.querySelector<HTMLElement>("[data-agent-update-job]");
  expect(job?.textContent).toContain("Exit code: 23");
  expect(
    card(page.container)!.querySelector<HTMLButtonElement>('[data-harness="codex"] [data-harness-action="update"]')
      ?.disabled,
  ).toBe(false);
  await show("unknown");
  expect(card(page.container)!.querySelector<HTMLElement>("[data-agent-update-job]")?.textContent).toContain(
    "Outcome unknown",
  );
  expect(
    card(page.container)!.querySelector<HTMLButtonElement>('[data-harness="codex"] [data-harness-action="update"]')
      ?.disabled,
  ).toBe(true);
  // An end observation without a process result is settled: it says so and allows another update.
  await show("exited", { outcome: "unknown" });
  job = card(page.container)!.querySelector<HTMLElement>("[data-agent-update-job]");
  expect(job?.dataset.agentUpdateJob).toBe("exited");
  expect(job?.textContent).toContain("Outcome unknown");
  expect(
    card(page.container)!.querySelector<HTMLButtonElement>('[data-harness="codex"] [data-harness-action="update"]')
      ?.disabled,
  ).toBe(false);
  page.unmount();
});

test("a recovered unstarted intent resumes only by an explicit click with its retained key", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const base = page.provider.harnesses;
  const show = async (canResume: boolean, state = "unknown") => {
    await act(async () =>
      page.provider.setHarnesses({
        ...base,
        jobs: [
          {
            machine: "machine_original",
            session: "session_original",
            cli: "codex",
            profiles: ["codex"],
            intent_key: "retained-original-key",
            state,
            can_resume: canResume,
          },
        ],
      } as typeof base),
    );
    await settle();
  };
  await show(true);
  const resume = card(page.container)!.querySelector<HTMLButtonElement>('[data-harness-action="resumeUpdate"]');
  expect(resume?.textContent).toContain("Resume original update");
  expect(page.provider.harnessRuns.filter((run) => run.action !== "refresh")).toEqual([]);
  expect(
    card(page.container)!.querySelector<HTMLButtonElement>('[data-harness="codex"] [data-harness-action="update"]')
      ?.disabled,
  ).toBe(true);
  await act(async () => resume!.click());
  await settle();
  expect(page.provider.harnessRuns.filter((run) => run.action !== "refresh")).toEqual([
    { action: "resumeUpdate", intent: "retained-original-key" },
  ]);
  for (const state of ["unknown", "pending", "created"]) {
    await show(false, state);
    expect(card(page.container)!.querySelector('[data-harness-action="resumeUpdate"]')).toBeNull();
  }
  page.unmount();
});

test("an intent nothing runs for can be dismissed by an explicit click with its retained key", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const base = page.provider.harnesses;
  const show = async (canDismiss: boolean, state = "unknown") => {
    await act(async () =>
      page.provider.setHarnesses({
        ...base,
        jobs: [
          {
            machine: "machine_original",
            session: "session_original",
            cli: "codex",
            profiles: ["codex"],
            intent_key: "retained-original-key",
            state,
            can_resume: false,
            can_dismiss: canDismiss,
          },
        ],
      } as typeof base),
    );
    await settle();
  };
  await show(true);
  const dismiss = card(page.container)!.querySelector<HTMLButtonElement>('[data-harness-action="dismissUpdate"]');
  expect(dismiss?.textContent).toContain("Dismiss");
  expect(card(page.container)!.querySelector('[data-harness-action="resumeUpdate"]')).toBeNull();
  await act(async () => dismiss!.click());
  await settle();
  expect(page.provider.harnessRuns.filter((run) => run.action !== "refresh")).toEqual([
    { action: "dismissUpdate", intent: "retained-original-key" },
  ]);
  for (const state of ["unknown", "pending", "created"]) {
    await show(false, state);
    expect(card(page.container)!.querySelector('[data-harness-action="dismissUpdate"]')).toBeNull();
  }
  page.unmount();
});

test("a channel the update owner cannot run (a Homebrew cask) offers no Update or Update All", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const cask = {
    id: "claude",
    name: null,
    kind: "claude-stdio",
    source: "path",
    problem: null,
    version: "2.0.5",
    latest: "2.0.9",
    outdated: true,
    auth: "signedIn" as const,
    update: { command: "brew upgrade --cask claude-code", elevated: false },
    ownerUpdate: false,
  };
  await act(async () => page.provider.setHarnesses({ loading: false, problem: null, harnesses: [cask] }));
  await settle();
  const element = card(page.container)!;
  expect(element.querySelector('[data-harness="claude"] [data-harness-action="update"]')).toBeNull();
  expect(element.querySelector('[data-harness-action="updateAll"]')).toBeNull();
  const manualCard = element.querySelector<HTMLElement>('[data-harness-update-card="claude"]')!;
  expect(manualCard.textContent).toContain("Run the command below to update Claude Code");
  expect(manualCard.querySelector('[data-harness-action="updateCard"]')).toBeNull();
  expect(manualCard.querySelector("[data-harness-update-command]")!.textContent).toBe(cask.update.command);
  // Its auto-update choice stays: acpmux runs that itself.
  expect(element.querySelector('[data-harness="claude"] input[data-harness-auto]')).not.toBeNull();
  page.unmount();
});

test("the card lists the host's harnesses with their names and reads them again when it opens", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container)!;
  expect(ids(element)).toEqual(["claude", "codex", "github-copilot-cli", "aider"]);
  expect(element.textContent).toContain("Claude Code");
  expect(element.textContent).toContain("GitHub Copilot");
  expect(page.provider.harnessRuns[0]).toEqual({ action: "refresh" });
  // A terminal-only harness has no sign-in buttons.
  const aider = element.querySelector<HTMLElement>('[data-harness="aider"]')!;
  expect(aider.querySelector("[data-harness-action]")).toBeNull();
  page.unmount();
});

test("Sign In and Check send the gesture for that harness; Browse ACP Registry sends its own", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container)!;
  const press = async (selector: string) => {
    await act(async () => element.querySelector<HTMLButtonElement>(selector)!.click());
    await settle();
  };
  await press('[data-harness="codex"] [data-harness-action="signIn"]');
  await press('[data-harness="github-copilot-cli"] [data-harness-action="check"]');
  await press('[data-harness-action="registry"]');
  expect(page.provider.harnessRuns.filter((run) => run.action !== "refresh")).toEqual([
    { action: "signIn", id: "codex" },
    { action: "check", id: "github-copilot-cli" },
    { action: "registry" },
  ]);
  page.unmount();
});

test("a change from the host shows without a reload; no daemon says why", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  await act(async () =>
    page.provider.setHarnesses({
      loading: false,
      problem: null,
      harnesses: [{ id: "grok", name: null, kind: "acp", source: "path", problem: "grok: not signed in" }],
    }),
  );
  await settle();
  let element = card(page.container)!;
  expect(ids(element)).toEqual(["grok"]);
  expect(element.textContent).toContain("grok: not signed in");
  await act(async () => page.provider.setHarnesses({ loading: false, problem: "unreachable", harnesses: [] }));
  await settle();
  element = card(page.container)!;
  expect(element.querySelector<HTMLElement>("[data-harnesses-problem]")!.dataset.harnessesProblem).toBe("unreachable");
  expect(element.textContent).toContain("acpmux did not answer");
  page.unmount();
});

test("an outdated harness shows both versions and an Update; one that needs sudo shows its command; Agents gets a badge", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container)!;
  const codex = element.querySelector<HTMLElement>('[data-harness="codex"]')!;
  expect(codex.querySelector("[data-harness-version]")!.textContent).toContain("0.3.1");
  expect(codex.querySelector("[data-harness-version]")!.textContent).toContain("0.4.0");
  expect(codex.querySelector('[data-harness-auth="signedOut"]')).not.toBeNull();
  const updateCard = element.querySelector<HTMLElement>('[data-harness-update-card="codex"]')!;
  expect(updateCard.textContent).toContain("Update Codex for reliable chats");
  expect(updateCard.textContent).toContain("Installed 0.3.1 · 0.4.0 available");
  expect(updateCard.textContent).toContain("Compatibility fixes");
  const updateButton = updateCard.querySelector<HTMLButtonElement>('[data-harness-action="updateCard"]')!;
  expect(updateButton).not.toBeNull();
  expect(document.getElementById(updateButton.getAttribute("aria-describedby")!)?.textContent).toBe(
    "Update Codex for reliable chats",
  );
  // An update that writes a folder this user cannot: the exact command, never a button that runs it.
  const claude = element.querySelector<HTMLElement>('[data-harness="claude"]')!;
  expect(claude.querySelector('[data-harness-action="update"]')).toBeNull();
  expect(claude.querySelector("[data-harness-command]")!.textContent).toBe(
    "sudo npm install -g @anthropic-ai/claude-code@latest",
  );
  const manualCard = element.querySelector<HTMLElement>('[data-harness-update-card="claude"]')!;
  expect(manualCard.textContent).toContain("Needs admin rights. Run in a terminal:");
  expect(manualCard.querySelector('[data-harness-action="updateCard"]')).toBeNull();
  expect(manualCard.querySelector("[data-harness-update-command]")!.textContent).toBe(
    "sudo npm install -g @anthropic-ai/claude-code@latest",
  );
  expect(claude.querySelector("[data-harness-auth]")).toBeNull();
  // An up-to-date one has neither.
  const copilot = element.querySelector<HTMLElement>('[data-harness="github-copilot-cli"]')!;
  expect(copilot.querySelector('[data-harness-action="update"], [data-harness-command]')).toBeNull();
  expect(page.container.querySelector('[data-section-link="agents"] [data-badge="update"]')).not.toBeNull();
  const press = async (selector: string) => {
    await act(async () => element.querySelector<HTMLButtonElement>(selector)!.click());
    await settle();
  };
  await press('[data-harness-update-card="codex"] [data-harness-action="updateCard"]');
  await press('[data-harness="codex"] [data-harness-action="update"]');
  await press('[data-harness-action="updateAll"]');
  await press('[data-harness-action="refresh"]');
  expect(page.provider.harnessRuns.filter((run) => run.action !== "refresh")).toEqual([
    { action: "update", id: "codex" },
    { action: "update", id: "codex" },
    { action: "updateAll" },
  ]);
  // Refresh asks the daemon to check again (after an update); opening the card does not.
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "refresh", recheck: true });
  // Up to date and signed in: no badge.
  await act(async () =>
    page.provider.setHarnesses({
      loading: false,
      problem: null,
      harnesses: [
        {
          id: "codex",
          name: null,
          kind: "acp",
          source: "path",
          problem: null,
          version: "0.4.0",
          latest: "0.4.0",
          outdated: false,
          auth: "signedIn",
          update: null,
        },
      ],
    }),
  );
  await settle();
  expect(page.container.querySelector('[data-section-link="agents"] [data-badge]')).toBeNull();
  expect(card(page.container)!.querySelector('[data-harness-action="updateAll"]')).toBeNull();
  page.unmount();
});

test("Update Automatically turns auto-update on for one harness; a failed auto-update says why", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const element = card(page.container)!;
  // Only a harness whose update needs no sudo offers it.
  expect(element.querySelector('[data-harness="claude"] [data-harness-auto]')).toBeNull();
  const box = element.querySelector<HTMLInputElement>('[data-harness="codex"] input[data-harness-auto]')!;
  expect(box.checked).toBe(false);
  await act(async () => box.click());
  await settle();
  expect(page.provider.harnessRuns.at(-1)).toEqual({ action: "autoUpdate", id: "codex", on: true });
  await act(async () =>
    page.provider.setHarnesses({
      loading: false,
      problem: null,
      harnesses: [
        {
          id: "codex",
          name: null,
          kind: "acp",
          source: "path",
          problem: null,
          version: "0.3.1",
          latest: "0.4.0",
          outdated: true,
          auth: "signedIn",
          update: { command: "npm install -g @openai/codex@latest", elevated: false },
          autoUpdate: true,
          lastAutoUpdate: { ok: false, detail: "npm ERR! network timeout" },
        },
      ],
    }),
  );
  await settle();
  const row = card(page.container)!.querySelector<HTMLElement>('[data-harness="codex"]')!;
  expect(row.querySelector<HTMLInputElement>("input[data-harness-auto]")!.checked).toBe(true);
  expect(row.querySelector("[data-harness-auto-failed]")!.textContent).toContain("npm ERR! network timeout");
  page.unmount();
});

test("an expired sign-in badges Agents and says so on its row, like a signed-out one", async () => {
  const { harnessesNeedAttention } = await import("./harnesses");
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const base = page.provider.harnesses;
  const harnesses = (base?.harnesses ?? []).map((row) => ({ ...row, outdated: false, auth: "signedIn" as const }));
  const expired = {
    ...base,
    harnesses: harnesses.map((row) => (row.id === "codex" ? { ...row, auth: "expired" as const } : row)),
  } as typeof base;
  expect(harnessesNeedAttention({ ...base, harnesses } as typeof base)).toBe(false);
  expect(harnessesNeedAttention(expired)).toBe(true);
  await act(async () => page.provider.setHarnesses(expired));
  await settle();
  const codex = card(page.container)!.querySelector<HTMLElement>('[data-harness="codex"]')!;
  expect(codex.querySelector('[data-harness-auth="expired"]')?.textContent).toBe("Signed out");
  page.unmount();
});
