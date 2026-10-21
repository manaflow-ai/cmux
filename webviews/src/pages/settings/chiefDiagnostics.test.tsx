// Settings > Chief > Diagnostics: the page ends with one glass card that says whether this Mac's
// Chief is running and lists every backend acpmux offers a Chief, each with Check: a real hello turn
// (`cmux.chief.backend.doctor`, as the Chief editor runs before it saves a new backend) whose answer
// shows in the row, with the failed step and its fix.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, ops } = await import("./testing");

const card = (container: ParentNode) => container.querySelector<HTMLElement>('[data-card="chief-diagnostics"]')!;
const row = (scope: ParentNode, id: string) => scope.querySelector<HTMLElement>(`[data-diagnostic="${id}"]`)!;
const status = (scope: ParentNode, id: string) => row(scope, id).querySelector(".chief-diagnostic-status")!.textContent;
const check = async (scope: ParentNode, id: string) => {
  await act(async () => row(scope, id).querySelector<HTMLButtonElement>("button")!.click());
  await settle();
};

test("the Chief page ends with a glass Diagnostics card: the Chief, then every backend", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  const sections = [...page.container.querySelectorAll<HTMLElement>("[data-card]")];
  expect(sections.at(-1)!.dataset.card).toBe("chief-diagnostics");
  const diagnostics = card(page.container);
  expect(diagnostics.classList.contains("ui-glass")).toBe(true);
  expect(diagnostics.querySelector(".group-title")!.textContent).toBe("Diagnostics");
  const rows = [...diagnostics.querySelectorAll<HTMLElement>("[data-diagnostic]")];
  expect(rows.map((entry) => entry.dataset.diagnostic)).toEqual(["chief", "claude", "codex"]);
  expect(row(diagnostics, "claude").querySelector(".row-title")!.textContent).toBe("Claude Code");
  expect(status(diagnostics, "chief")).toBe("Running");
  expect(status(diagnostics, "codex")).toBe("Ready");
  page.unmount();
});

test("Check runs the backend's hello turn and says that it answered", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  await check(card(page.container), "codex");
  expect(ops(page.provider, "cmux.chief.backend.doctor").at(-1)).toMatchObject({ id: "codex", prompt: true });
  expect(status(card(page.container), "codex")).toBe("Checked: it answered.");
  expect(status(card(page.container), "claude")).toBe("Ready");
  page.unmount();
});

test("a failed check names the step and its fix", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    mock: {
      chiefDoctor: {
        codex: { ok: false, steps: [{ name: "prompt", ok: false, detail: "not signed in", fix: "Run codex login." }] },
      },
    },
  });
  await settle();
  await check(card(page.container), "codex");
  const failed = row(card(page.container), "codex");
  expect(failed.querySelector(".chief-diagnostic-status")!.textContent).toBe("The check failed at prompt.");
  expect(failed.textContent).toContain("not signed in");
  expect(failed.textContent).toContain("Fix: Run codex login.");
  page.unmount();
});

test("with no Chief running, the card says so and Check stays off", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    mock: { failing: { "cmux.chief.profile.list": "cmux.chief.unavailable" } },
  });
  await settle();
  const diagnostics = card(page.container);
  expect(status(diagnostics, "chief")).toBe("Not running");
  expect(row(diagnostics, "chief").textContent).toContain("Chiefs show here when this build's Chief is running.");
  expect(row(diagnostics, "codex").querySelector<HTMLButtonElement>("button")!.disabled).toBe(true);
  page.unmount();
});
