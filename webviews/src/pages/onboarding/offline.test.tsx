// The offline line follows the webview's own network state: it shows once the webview has been offline
// CONNECTION_QUIET_MS (a blip says nothing) and goes by itself when the network returns, with no click.
import { afterAll, afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { CONNECTION_QUIET_MS } from "../../ui/lasting";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { agentsState } from "./fixtures";
import table from "./generated/strings.json";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";

const restore = installDom();
afterAll(() => restore());
afterEach(() => jest.useRealTimers());

const strings = createStrings(table, ["en"]);

function setOnline(online: boolean) {
  Object.defineProperty(window.navigator, "onLine", { configurable: true, get: () => online });
  window.dispatchEvent(new window.Event(online ? "online" : "offline"));
}

test("a blip offline says nothing; a lasting one shows one line; back online it goes by itself", async () => {
  jest.useFakeTimers();
  setOnline(true);
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const store = new OnboardingStore(null, agentsState("mixed"));
  await act(async () => root.render(<OnboardingPage store={store} strings={strings} />));
  expect(host.querySelector(".onb-offline")).toBeNull();

  await act(async () => setOnline(false));
  expect(host.querySelector(".onb-offline")).toBeNull();
  await act(async () => jest.advanceTimersByTime(CONNECTION_QUIET_MS - 100));
  expect(host.querySelector(".onb-offline")).toBeNull();
  await act(async () => setOnline(true));
  await act(async () => setOnline(false));
  await act(async () => jest.advanceTimersByTime(CONNECTION_QUIET_MS - 100));
  expect(host.querySelector(".onb-offline")).toBeNull();
  await act(async () => jest.advanceTimersByTime(200));
  const line = host.querySelector(".onb-offline");
  expect(line?.textContent).toBe("This Mac is offline. Sign-ins and installs work once it’s back.");
  expect(line?.tagName).toBe("OUTPUT");

  await act(async () => setOnline(true));
  expect(host.querySelector(".onb-offline")).toBeNull();
  await act(async () => root.unmount());
  host.remove();
});
