// l10n-allow-file: test fixtures.
// The guest page's open-in-app step (agent-session/guest/appLink.ts, OpenInApp.tsx): the link is
// handed to the cmux app by its URL scheme with the secret only in that URL's fragment, never in
// anything a server is asked for; with no app the page carries on to the guest page by itself; with
// the app the card stays with a choice to continue in the browser. Inside the app (`in_app=1`), after
// the browser was chosen or once joined, the step is skipped.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "https://share.cmux.dev/g/c2hhcmUtMDAwMDAwMDAwMDAx",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { OpenInApp, WithOpenInApp } = await import("../src/agent-session/guest/OpenInApp");
const { useEffect } = await import("react");
const { appLinkUrl, appScheme, chooseBrowser, offersApp, tryOpenApp } =
  await import("../src/agent-session/guest/appLink");
type AppOpenWindow = import("../src/agent-session/guest/appLink").AppOpenWindow;
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { memoryStorage } = await import("../src/agent-session/guest/fixtures/liveChat");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const SHARE = "c2hhcmUtMDAwMDAwMDAwMDAx";
const SECRET = "c2VjcmV0LTAwMDAwMDAwMDAx";

/** A window whose app attempt is scripted: `took` hides the page (the app came forward). */
function fakeWindow(took: boolean) {
  const listeners = new Map<string, () => void>();
  const timers = new Map<number, () => void>();
  let next = 1;
  const assigned: string[] = [];
  const document: { visibilityState: DocumentVisibilityState } = { visibilityState: "visible" };
  const hide = () => {
    document.visibilityState = "hidden";
    listeners.get("visibilitychange")?.();
  };
  const win: AppOpenWindow = {
    location: {
      assign: (url) => {
        assigned.push(url);
        if (took) queueMicrotask(hide);
      },
    },
    document,
    addEventListener: (type, listener) => listeners.set(type, listener),
    removeEventListener: (type) => listeners.delete(type),
    setTimeout: (handler) => {
      const id = next++;
      timers.set(id, handler);
      return id;
    },
    clearTimeout: (id) => timers.delete(id),
  };
  const elapse = () => {
    const due = Array.from(timers.values());
    timers.clear();
    for (const handler of due) handler();
  };
  return { win, assigned, listeners, timers, elapse, document };
}

test("the app URL keeps the secret in its fragment only, never in the page address a server is asked for", () => {
  const url = appLinkUrl("cmux", "https://share.cmux.dev", { shareId: SHARE, secret: SECRET });
  expect(url).toBe(`cmux://share?link=${encodeURIComponent(`https://share.cmux.dev/g/${SHARE}`)}#${SECRET}`);
  const parsed = new URL(url);
  // Not a web request: the browser hands a custom scheme to the operating system.
  expect(parsed.protocol).toBe("cmux:");
  expect(parsed.hash).toBe(`#${SECRET}`);
  const page = new URL(parsed.searchParams.get("link")!);
  expect(page.href).toBe(`https://share.cmux.dev/g/${SHARE}`);
  expect(page.href).not.toContain(SECRET);
  expect(url.slice(0, url.indexOf("#"))).not.toContain(SECRET);
  // An invite is joined by account: no secret travels at all.
  const invite = appLinkUrl("cmux", "https://share.cmux.dev", { shareId: SHARE, secret: SECRET, invite: true });
  expect(invite).toBe(`cmux://share?link=${encodeURIComponent(`https://share.cmux.dev/i/${SHARE}`)}`);
});

test("a link opens cmux NIGHTLY unless it names its build, `?app=` names only a cmux scheme, and a local page offers none", () => {
  const at = (search = "", protocol = "https:") => appScheme({ protocol, search });
  expect(at()).toBe("cmux-nightly");
  // Each build the daemon names (cmux-cloud-config `callback_scheme`): NEXT DEV, a Debug build, a tagged one, RC.
  for (const scheme of ["cmux-next-dev", "cmux-dev", "cmux-dev-my-tag", "cmux-rc", "cmux", "cmux.my-build"]) {
    expect(at(`?app=${scheme}`)).toBe(scheme);
  }
  expect(at("?app=javascript")).toBe("cmux-nightly");
  expect(at("?app=https")).toBe("cmux-nightly");
  expect(at("?app=cmux-")).toBe("cmux-nightly");
  expect(at("?app=cmux..x")).toBe("cmux-nightly");
  expect(at("?app=cmuxevil")).toBe("cmux-nightly");
  expect(at("", "http:")).toBeUndefined();
  expect(at("?app=cmux-dev", "http:")).toBe("cmux-dev");
});

test("the step is skipped inside the app, after the browser was chosen, once joined and with no share", () => {
  const storage = memoryStorage();
  const page = { protocol: "https:", search: "" };
  expect(offersApp(page, storage, SHARE, false)).toBe(true);
  expect(offersApp({ ...page, search: "?in_app=1" }, storage, SHARE, false)).toBe(false);
  expect(offersApp(page, storage, SHARE, true)).toBe(false);
  expect(offersApp(page, storage, "", false)).toBe(false);
  expect(offersApp({ protocol: "http:", search: "" }, storage, SHARE, false)).toBe(false);
  chooseBrowser(storage, SHARE);
  expect(offersApp(page, storage, SHARE, false)).toBe(false);
  expect(offersApp(page, storage, "c2hhcmUtb3RoZXI", false)).toBe(true);
});

test("an app attempt settles once, and removes its timer and listeners", async () => {
  const none = fakeWindow(false);
  const pending = tryOpenApp(none.win, "cmux://share", 1500);
  expect(none.assigned).toEqual(["cmux://share"]);
  none.elapse();
  expect(await pending).toBe(false);
  expect(none.listeners.size).toBe(0);
  const app = fakeWindow(true);
  expect(await tryOpenApp(app.win, "cmux://share", 1500)).toBe(true);
  expect(app.listeners.size).toBe(0);
  expect(app.timers.size).toBe(0);
});

test("a page that stays visible was not taken by the app: a visibility change to visible, or a blur, is not proof", async () => {
  const stay = fakeWindow(false);
  const pending = tryOpenApp(stay.win, "cmux://share", 1500);
  // The visitor switched windows and came back: the page never hid.
  stay.listeners.get("visibilitychange")?.();
  expect(stay.listeners.size).toBe(2);
  stay.elapse();
  expect(await pending).toBe(false);
});

test("a page opened hidden asks the app only once it is shown, so a background tab is not taken for the app", async () => {
  const background = fakeWindow(false);
  background.document.visibilityState = "hidden";
  const pending = tryOpenApp(background.win, "cmux://share", 1500);
  await Promise.resolve();
  expect(background.assigned).toEqual([]);
  expect(background.timers.size).toBe(0);
  // Shown: now it asks, and with no app the page stays visible, so the attempt answers no.
  background.document.visibilityState = "visible";
  background.listeners.get("visibilitychange")?.();
  await Promise.resolve();
  expect(background.assigned).toEqual(["cmux://share"]);
  background.elapse();
  expect(await pending).toBe(false);
  expect(background.listeners.size).toBe(0);
});

test("a page that unmounts while it waits to be shown never asks the app later (a page restored from bfcache)", async () => {
  const background = fakeWindow(false);
  background.document.visibilityState = "hidden";
  const controller = new AbortController();
  void tryOpenApp(background.win, "cmux://share", 1500, controller.signal);
  controller.abort();
  expect(background.listeners.size).toBe(0);
  background.document.visibilityState = "visible";
  background.listeners.get("visibilitychange")?.();
  await Promise.resolve();
  expect(background.assigned).toEqual([]);
});

async function mount(took: boolean) {
  const fake = fakeWindow(took);
  const appUrl = appLinkUrl("cmux", "https://share.cmux.dev", { shareId: SHARE, secret: SECRET });
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  let continued = 0;
  await act(async () => {
    root.render(<OpenInApp appUrl={appUrl} win={fake.win} onContinue={() => continued++} />);
  });
  return { fake, host, root, appUrl, continued: () => continued };
}

test("with no app, the page carries on to the guest page by itself", async () => {
  const page = await mount(false);
  expect(page.fake.assigned).toEqual([page.appUrl]);
  expect(page.host.textContent).toContain(translate("guest.app.opening"));
  expect(page.continued()).toBe(0);
  await act(async () => page.fake.elapse());
  expect(page.continued()).toBe(1);
  await act(async () => page.root.unmount());
});

test("when the app takes the link, the card stays with Open in cmux and Continue in browser", async () => {
  const page = await mount(true);
  await act(async () => {
    await Promise.resolve();
  });
  expect(page.host.textContent).toContain(translate("guest.app.opened"));
  expect(page.continued()).toBe(0);
  const open = page.host.querySelector<HTMLAnchorElement>("a.guest-app__open")!;
  expect(open.textContent).toBe(translate("guest.app.open"));
  expect(open.getAttribute("href")).toBe(page.appUrl);
  const browser = [...page.host.querySelectorAll("button")].find(
    (b) => b.textContent === translate("guest.app.browser"),
  )!;
  await act(async () => browser.click());
  expect(page.continued()).toBe(1);
  await act(async () => page.root.unmount());
});

test("the guest page mounts at once beneath the banner: its join card and whoami never wait for the app attempt", async () => {
  const fake = fakeWindow(false);
  const appUrl = appLinkUrl("cmux", "https://share.cmux.dev", { shareId: SHARE, secret: SECRET });
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const started: string[] = [];
  // Stands in for GuestPage: its whoami request starts on mount.
  function Page() {
    useEffect(() => void started.push("whoami"), []);
    return <main data-testid="join-card">Join</main>;
  }
  let chose = 0;
  await act(async () => {
    root.render(
      <WithOpenInApp appUrl={appUrl} win={fake.win} onChooseBrowser={() => chose++}>
        <Page />
      </WithOpenInApp>,
    );
  });
  // The attempt is pending (no timer fired), and the page is already there with its request started.
  expect(fake.assigned).toEqual([appUrl]);
  expect(fake.timers.size).toBe(1);
  expect(host.querySelector("[data-testid=join-card]")).not.toBeNull();
  expect(started).toEqual(["whoami"]);
  expect(host.querySelector("[data-testid=guest-open-in-app]")).not.toBeNull();
  // No app: the banner goes, the page stays, mounted once.
  await act(async () => fake.elapse());
  expect(host.querySelector("[data-testid=guest-open-in-app]")).toBeNull();
  expect(host.querySelector("[data-testid=join-card]")).not.toBeNull();
  expect(started).toEqual(["whoami"]);
  expect(chose).toBe(1);
  await act(async () => root.unmount());
});

test("an unmount right after the page is shown still asks the app nothing", async () => {
  const background = fakeWindow(false);
  background.document.visibilityState = "hidden";
  const controller = new AbortController();
  const pending = tryOpenApp(background.win, "cmux://share", 1500, controller.signal);
  background.document.visibilityState = "visible";
  background.listeners.get("visibilitychange")?.();
  controller.abort();
  expect(await pending).toBe(false);
  expect(background.assigned).toEqual([]);
});
