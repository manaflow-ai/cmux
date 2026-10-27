// BRING-YOUR-OWN-HARNESS (Lawrence 2026-10-08: "ensure people are able to add their own ACP
// stuff, via UI, cli, mcp, cmd shift p"): Settings > Agents lists every harness, adds one from the
// ACP Registry or a custom command, checks it (the doctor's steps inline) and removes it with Undo.
// Every gesture is one `cmux.settings.agents.run`; an older acpmux shows the CLI instead.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, ops } = await import("./testing");

const harness = (container: ParentNode, id: string) =>
  container.querySelector<HTMLElement>(`[data-agent-harness="${id}"]`);
const card = (container: ParentNode) => container.querySelector<HTMLElement>('[data-card="agentHarnesses"]')!;
const button = (scope: ParentNode, label: string) =>
  [...scope.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === label)!;

test("Your Agents shows the profiles you added, beside the full Harnesses list, and refreshes on open", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  // Built-in and registry harnesses are the Harnesses card's (cx-mg91); this card has yours.
  expect(harness(page.container, "claude")).toBeNull();
  expect(harness(page.container, "gemini")).toBeNull();
  expect(harness(page.container, "acme-agent")?.textContent).toContain("Your profile");
  expect(harness(page.container, "acme-agent")?.textContent).toContain("the model probe timed out");
  expect(ops(page.provider, "cmux.settings.agents.run")).toContainEqual({ action: "refresh" });
  page.unmount();
});

test("an ACP Registry agent is added with one click and the list follows", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.registry" });
  const row = () => page.container.querySelector<HTMLElement>('[data-registry-agent="goose"]')!;
  expect(row().textContent).toContain("Installed");
  await act(async () => row().querySelector<HTMLButtonElement>("button")!.click());
  await settle();
  expect(ops(page.provider, "cmux.settings.agents.run")).toContainEqual({ action: "add", registry: "goose" });
  expect(harness(page.container, "goose")?.textContent).toContain("Your profile");
  expect(row().querySelector("button")!.textContent).toBe("Added");
  // An agent with no way to start here cannot be added.
  expect(page.container.querySelector('[data-registry-agent="auggie"] button')!.hasAttribute("disabled")).toBe(true);
  page.unmount();
});

test("Add ACP Agent… opens the custom form; it sends the command, args and secret key names", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.add" });
  const form = page.container.querySelector<HTMLFormElement>("[data-agents-custom]")!;
  await changeValue(form.querySelector<HTMLInputElement>('[aria-label="Command"]')!, "/opt/acme/bin/acme");
  await changeValue(form.querySelector<HTMLInputElement>('[aria-label="Arguments"]')!, 'acp --mode "fast lane"');
  await changeValue(form.querySelector<HTMLInputElement>('[aria-label="Secret env keys"]')!, "ACME_TOKEN, ACME_ORG");
  await act(async () => button(form, "Add").click());
  await settle();
  expect(ops(page.provider, "cmux.settings.agents.run").at(-1)).toEqual({
    action: "add",
    command: "/opt/acme/bin/acme",
    args: ["acp", "--mode", "fast lane"],
    protocol: "acp",
    envKeys: ["ACME_TOKEN", "ACME_ORG"],
  });
  expect(harness(page.container, "acme")).not.toBeNull();
  expect(page.container.querySelector("[data-agents-custom]")).toBeNull();
  page.unmount();
});

test("a daemon refusal shows its reason and keeps the form open", async () => {
  const page = await renderPage({ path: "/settings/agents?focus=agents.add" });
  const form = () => page.container.querySelector<HTMLFormElement>("[data-agents-custom]")!;
  await changeValue(form().querySelector<HTMLInputElement>('[aria-label="Command"]')!, "claude");
  await act(async () => button(form(), "Add").click());
  await settle();
  expect(page.container.querySelector('[role="alert"]')?.textContent).toContain("claude already has a profile");
  expect(form()).not.toBeNull();
  page.unmount();
});

test("Check runs the doctor and shows each step with its fix", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await act(async () => button(harness(page.container, "acme-agent")!, "Check").click());
  await settle();
  expect(ops(page.provider, "cmux.settings.agents.run")).toContainEqual({ action: "doctor", id: "acme-agent" });
  const doctor = harness(page.container, "acme-agent")!.querySelector("[data-agent-doctor]")!;
  expect(doctor.textContent).toContain("Check failed");
  expect(doctor.querySelector('[data-step-status="fail"]')?.textContent).toContain("Run the agent once in a terminal");
  expect(doctor.querySelector('[data-step-status="skip"]')).not.toBeNull();
  page.unmount();
});

test("Remove moves a user profile aside and Undo restores it", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  await act(async () => button(harness(page.container, "acme-agent")!, "Remove").click());
  await settle();
  expect(harness(page.container, "acme-agent")).toBeNull();
  expect(page.container.textContent).toContain("Removed acme-agent.");
  await act(async () => button(card(page.container), "Undo").click());
  await settle();
  expect(ops(page.provider, "cmux.settings.agents.run").at(-1)).toEqual({
    action: "restore",
    backup: "acme-agent.toml.1",
  });
  expect(harness(page.container, "acme-agent")).not.toBeNull();
  page.unmount();
});

test("an acpmux without the operations shows the CLI and no Add, Check or Remove", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  page.provider.agents.state = { ...page.provider.agents.state, manages: false };
  await act(async () => button(card(page.container), "Refresh").click());
  await settle();
  expect(page.container.querySelector("[data-agents-cli]")?.textContent).toContain("cmux harness add");
  expect(button(card(page.container), "Add Agent…")).toBeUndefined();
  expect(button(harness(page.container, "acme-agent")!, "Remove")).toBeUndefined();
  page.unmount();
});

// User 12922: a custom harness's icon is set from Settings (one emoji, an SF Symbol name, an agent,
// or a PNG/SVG) and Automatic gives it back to acpmux; the row draws the icon acpmux resolved.
test("a profile's icon is set from its row and the row draws it", async () => {
  const page = await renderPage({ path: "/settings/agents" });
  const row = () => harness(page.container, "acme-agent")!;
  // Unset: the monogram acpmux picked, never an empty box.
  expect(row().querySelector(".agent-mark-monogram")?.textContent).toBe("AA");
  await act(async () => button(row(), "Icon…").click());
  const editor = () => page.container.querySelector<HTMLElement>('[data-agent-icon-editor="acme-agent"]')!;
  await changeValue(editor().querySelector<HTMLInputElement>('[aria-label="Icon…"]')!, "🦊");
  await act(async () => button(editor(), "Set Icon").click());
  await settle();
  expect(ops(page.provider, "cmux.settings.agents.run")).toContainEqual({
    action: "icon",
    id: "acme-agent",
    icon: "🦊",
  });
  expect(row().querySelector(".agent-mark-emoji")?.textContent).toBe("🦊");
  expect(page.container.querySelector('[data-agent-icon-editor="acme-agent"]')).toBeNull();
  // Automatic: the icon line goes, acpmux picks again.
  await act(async () => button(row(), "Icon…").click());
  await act(async () => button(editor(), "Automatic").click());
  await settle();
  expect(ops(page.provider, "cmux.settings.agents.run")).toContainEqual({
    action: "icon",
    id: "acme-agent",
    clear: true,
  });
  expect(row().querySelector(".agent-mark-monogram")?.textContent).toBe("AA");
  // A dropped PNG goes as its bytes; acpmux copies it next to the profile.
  await act(async () => button(row(), "Icon…").click());
  const png = new File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], "logo.png", { type: "image/png" });
  await act(async () => {
    const drop = new Event("drop", { bubbles: true, cancelable: true }) as Event & { dataTransfer: unknown };
    drop.dataTransfer = { files: [png] };
    editor().dispatchEvent(drop);
  });
  await settle();
  expect(ops(page.provider, "cmux.settings.agents.run")).toContainEqual({
    action: "icon",
    id: "acme-agent",
    data: "iVBORw==",
    ext: "png",
  });
  expect(row().querySelector<HTMLImageElement>("img.agent-mark-image")?.src).toBe("data:image/png;base64,iVBORw==");
  page.unmount();
});
