// Settings > Automations (labs.automations). Off by default, the cloud automation card draws
// nothing and does not ask the host for its autocloud state. Turning the lab on opts into the
// existing card and its first refresh.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderCard } = await import("./testing");
const { AutomationsCard } = await import("./components/AutomationsCard");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="automationsCloud"]');

test("off by default the card draws nothing and reads no autocloud state", async () => {
  const page = await renderCard(<AutomationsCard />);
  expect(card(page.container)).toBeNull();
  expect(page.provider.log.some((call) => call.op === "cmux.settings.autocloud.state")).toBe(false);
  expect(page.provider.log.some((call) => call.op === "cmux.settings.autocloud.run")).toBe(false);
  page.unmount();
});

test("with the lab on it renders the card and refreshes autocloud", async () => {
  const page = await renderCard(<AutomationsCard />, { mock: { values: { "labs.automations": true } } });
  expect(card(page.container)).not.toBeNull();
  expect(page.provider.log.some((call) => call.op === "cmux.settings.autocloud.state")).toBe(true);
  expect(
    page.provider.log.some(
      (call) => call.op === "cmux.settings.autocloud.run" && (call.params as { action?: string }).action === "refresh",
    ),
  ).toBe(true);
  page.unmount();
});
