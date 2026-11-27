// Settings > Agents > Worktree Setup: the card lists the session host's projects, shows what the
// repository's files say under each script, and saves the project's own recipe with
// `project.update` field `worktree` (a saved script wins, an empty one turns the repository's off,
// null clears it). A build whose page relay cannot reach the projects says so instead.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, click, ops } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="worktreeSetup"]')!;
const field = (container: HTMLElement, id: string) =>
  card(container).querySelector<HTMLTextAreaElement>(`[data-worktree-field="${id}"] textarea`)!;
const note = (container: HTMLElement, id: string) =>
  card(container).querySelector<HTMLElement>(`[data-worktree-repository="${id}"]`)!.textContent ?? "";
const type = (element: HTMLTextAreaElement, value: string) =>
  changeValue(element as unknown as HTMLInputElement, value);

test("the first project's scripts show the repository's under each field, and nothing is saved", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  expect(card(page.container)).not.toBeNull();
  expect(field(page.container, "setup").value).toBe("");
  expect(field(page.container, "setup").placeholder).toBe("bun install");
  expect(note(page.container, "setup")).toContain("Repository: bun install");
  expect(note(page.container, "teardown")).toContain("The repository sets none.");
  expect(note(page.container, "include")).toContain(".env, .env.local");
  expect(card(page.container).textContent).toContain(".worktreeinclude, .cmux/worktree.toml");
  expect(card(page.container).querySelector<HTMLButtonElement>('[data-worktree="save"]')!.disabled).toBe(true);
  expect(card(page.container).querySelector('[data-worktree="clear"]')).toBeNull();
  page.unmount();
});

test("a replaced script and a turned-off one save as the project's recipe", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  await type(field(page.container, "setup"), "bun install --frozen-lockfile");
  expect(note(page.container, "setup")).toContain("Replaces the repository's.");
  await type(field(page.container, "run"), "x");
  await type(field(page.container, "run"), "");
  expect(note(page.container, "run")).toContain("Off: the repository's does not run.");
  await type(field(page.container, "include"), "secrets/dev.json\n\n");
  await click(card(page.container).querySelector<HTMLButtonElement>('[data-worktree="save"]')!);
  expect(ops(page.provider, "cmux.settings.worktree.save")).toEqual([
    {
      path: "/Users/you/src/cmux",
      worktree: { setup: "bun install --frozen-lockfile", run: "", include: ["secrets/dev.json"] },
    },
  ]);
  // Read back: the saved recipe is the one shown, with Clear Saved.
  expect(field(page.container, "setup").value).toBe("bun install --frozen-lockfile");
  expect(card(page.container).querySelector('[data-worktree="clear"]')).not.toBeNull();
  page.unmount();
});

test("Use Repository's drops the project's script; Clear Saved sends null", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const select = card(page.container).querySelector<HTMLSelectElement>("select")!;
  await changeValue(select, "/Users/you/src/website");
  expect(field(page.container, "setup").value).toBe("pnpm install");
  expect(field(page.container, "include").value).toBe("config/local.json");
  await click(card(page.container).querySelector<HTMLButtonElement>('[data-worktree-use="setup"]')!);
  expect(field(page.container, "setup").value).toBe("");
  expect(note(page.container, "setup")).not.toContain("Replaces");
  await click(card(page.container).querySelector<HTMLButtonElement>('[data-worktree="clear"]')!);
  expect(ops(page.provider, "cmux.settings.worktree.save")).toEqual([
    { path: "/Users/you/src/website", worktree: null },
  ]);
  expect(page.provider.worktreeProjects.find((row) => row.name === "website")?.saved).toBeUndefined();
  page.unmount();
});

// CMUX-374: with no repository script the field's state stayed "repository" whatever the project set,
// so Use Repository's never showed, and a project script (or an emptied one, saved as "") could not go
// back to following the repository.
test("Use Repository's shows for a project script where the repository sets none", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  const use = () => card(page.container).querySelector<HTMLButtonElement>('[data-worktree-use="teardown"]');
  expect(note(page.container, "teardown")).toContain("The repository sets none.");
  expect(use()).toBeNull();
  await type(field(page.container, "teardown"), "rm -rf tmp");
  expect(use()).not.toBeNull();
  await type(field(page.container, "teardown"), "");
  expect(use()).not.toBeNull();
  await click(use()!);
  expect(use()).toBeNull();
  expect(field(page.container, "teardown").value).toBe("");
  // Back to the saved recipe (none): nothing to save.
  expect(card(page.container).querySelector<HTMLButtonElement>('[data-worktree="save"]')!.disabled).toBe(true);
  page.unmount();
});

test("a project's fields stay locked until its own recipe has been read", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await settle();
  let answer = () => {};
  page.provider.worktreeReadHold = new Promise<void>((resolve) => {
    answer = resolve;
  });
  const select = card(page.container).querySelector<HTMLSelectElement>("select")!;
  await changeValue(select, "/Users/you/src/website");
  // The first project's draft is still shown: nothing in it can be edited, saved or cleared.
  expect(field(page.container, "setup").disabled).toBe(true);
  expect(card(page.container).querySelector<HTMLButtonElement>('[data-worktree="save"]')!.disabled).toBe(true);
  const clear = card(page.container).querySelector<HTMLButtonElement>('[data-worktree="clear"]');
  expect(clear === null || clear.disabled).toBe(true);
  page.provider.worktreeReadHold = null;
  answer();
  await settle();
  expect(field(page.container, "setup").disabled).toBe(false);
  expect(field(page.container, "setup").value).toBe("pnpm install");
  expect(ops(page.provider, "cmux.settings.worktree.save")).toEqual([]);
  page.unmount();
});

test("a build whose relay cannot reach the projects says so", async () => {
  const page = await renderPage({
    path: "/settings/agents",
    mock: { failing: { "cmux.settings.worktree.list": "cmux.protocol.unknown_op" } },
  });
  await settle();
  expect(card(page.container).querySelector("[data-worktree-unavailable]")).not.toBeNull();
  expect(card(page.container).querySelector("[data-worktree-form]")).toBeNull();
  page.unmount();
});
