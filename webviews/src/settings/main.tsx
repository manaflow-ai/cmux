// Entry of the Settings page. Inside the app the native transport relays to the daemon;
// opened anywhere else (the dev server) it runs on the in-memory fake.
import { createRoot } from "react-dom/client";
import { SettingsPage } from "./components/SettingsPage";
import { FakeTransport } from "./fakeTransport";
import { NativeTransport, nativeHandler } from "./nativeTransport";
import { SettingsStore } from "./store";
import { setLocale, t } from "./strings";
import { applySettingsTheme } from "./theme";
import { isErrorReply, type ReadyReply } from "./wire";

async function start(): Promise<void> {
  const handler = nativeHandler();
  const transport = handler ? new NativeTransport(handler) : new FakeTransport();
  const reply = await transport.request("ready", {});
  const ready: ReadyReply = isErrorReply(reply) ? {} : reply;
  setLocale(ready.locale ?? navigator.language);
  document.title = t("settingsPage.title");
  if (ready.theme) applySettingsTheme(ready.theme);
  if (ready.initialRoute && window.location.hash.replace(/^#\/?/, "") === "") {
    window.location.hash = ready.initialRoute.startsWith("#") ? ready.initialRoute : `#${ready.initialRoute}`;
  }
  const store = new SettingsStore(transport);
  store.setDomains(ready.domains);
  void store.refresh();
  createRoot(document.getElementById("root")!).render(<SettingsPage store={store} />);
}

void start();
