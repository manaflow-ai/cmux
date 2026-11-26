// A browser stamps each animation frame on the clock `performance.now()` reads. jsdom's
// `requestAnimationFrame` (pretendToBeVisual) stamps it from the jsdom window's creation instead, so
// a page that compares a frame's time with the global `performance.now()` (scrollMotion.ts's
// runScroll) read seconds of negative elapsed time and its glide stalled: under 8 parallel runs
// transcript-jump-momentum failed 10 of 48. Every window a test file creates goes through
// createWindow, so wrapping it here (before anything loads jsdom's api.js, which keeps its own
// reference) gives every window's frames the global clock, read when the frame runs.
{
  const { createRequire } = await import("node:module");
  const { dirname, join } = await import("node:path");
  const require = createRequire(import.meta.url);
  const root = dirname(require.resolve("jsdom/package.json"));
  const windowModule = require(join(root, "lib/jsdom/browser/Window.js")) as {
    createWindow: (options: unknown) => Record<string, unknown>;
  };
  const createWindow = windowModule.createWindow;
  windowModule.createWindow = (options) => {
    const window = createWindow(options);
    const frame = window.requestAnimationFrame as ((callback: unknown) => number) | undefined;
    if (typeof frame === "function")
      window.requestAnimationFrame = function requestAnimationFrame(callback: unknown) {
        // A non-function keeps jsdom's own TypeError.
        if (typeof callback !== "function") return frame.call(this, callback);
        return frame.call(this, function (this: unknown) {
          return (callback as (time: number) => unknown).call(this, globalThis.performance.now());
        });
      };
    return window;
  };
}

// Base UI decides once, when its module first loads, whether to run layout effects: it checks for
// a global `document` (@base-ui/utils/useIsoLayoutEffect). Test files install jsdom in beforeAll,
// after their imports have loaded Base UI, and bun shares one module cache across files, so the
// first file to import src/ui would turn Base UI's layout effects off for every file after it
// (popovers and dialogs that never open). Load that one module here with a stand-in document.
const scope = globalThis as Record<string, unknown>;
const hadDocument = "document" in scope;
if (!hadDocument) scope.document = {};
await import("@base-ui/utils/useIsoLayoutEffect");
if (!hadDocument) delete scope.document;
export {};

// The pages' strings tables are build output (gen-strings.mjs): rewrite any whose catalogs or
// settings schema changed since they were written, so a test never reads a table from another
// checkout state. Best effort: a missing translation fails strings.test.ts, not every file.
{
  const { writeStrings } = await import("../scripts/pages/gen-strings.mjs");
  writeStrings({ ifStale: true, bestEffort: true, log: () => {} });
  // The agent pane table is consumed immediately below. Check it by content, not time, so a
  // restored ignored output cache cannot leave tests rendering localization keys. A rebuild from
  // its 12 MB catalog took about 200 ms of every `bun test` process; the content check about 20.
  writeStrings({ only: ["agentPane"], ifUnchanged: true, bestEffort: true, log: () => {} });
  // The feature tips table is build output too (gen-feature-tips.mjs): made from this tree's highlights.
  const { writeFeatureTips } = await import("../scripts/pages/gen-feature-tips.mjs");
  writeFeatureTips({ log: () => {} });
  // The design scale's Tailwind theme and token list (gen-design-scale.mjs) are build output as well.
  const { writeDesignScale } = await import("../scripts/pages/gen-design-scale.mjs");
  writeDesignScale({ log: () => {} });
  // So are the pane and acpmux protocol types (pane-protocol-codegen.ts, acpmux-protocol-codegen.ts),
  // made from the committed IR; each file is written only when its content changed.
  const { writePaneProtocol } = await import("../scripts/pane-protocol-codegen");
  writePaneProtocol({ log: () => {} });
  const { writeAcpmuxProtocol } = await import("../scripts/acpmux-protocol-codegen");
  writeAcpmuxProtocol({ log: () => {} });
}

// React reads its commit hook once, when react-dom loads: install the row render counter
// (support/commitRenders.ts) first, so a jsdom test can count which rows a change rendered.
{
  const { installRowRenderCounter } = await import("./support/commitRenders");
  installRowRenderCounter();
}

// React's scheduler keeps its queue private, and react-dom copies its entry points when it first
// loads: count the tasks it queues from here on, before anything loads react-dom, so a teardown can
// wait for them (support/domTeardown.ts: a scheduler task that runs after a file deletes its DOM
// globals fails the file with "window is not defined" between tests).
{
  const { trackReactScheduler } = await import("./support/domTeardown");
  trackReactScheduler();
}

// react-dom picks the animationend event name once, when it first loads: without
// window.AnimationEvent it listens for the prefixed webkitAnimationEnd for the rest of the run,
// and onAnimationEnd handlers never fire (the agent pane's Search chats sheet exit). WebKit has
// AnimationEvent, so load react-dom here with a jsdom window that has it, before any test file.
{
  const { JSDOM } = await import("jsdom");
  const { window } = new JSDOM("<!doctype html>");
  (window as unknown as Record<string, unknown>).AnimationEvent ??= window.Event;
  const keys = ["window", "document", "navigator", "HTMLElement"] as const;
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
  });
  await import("react-dom");
  await import("react-dom/client");
  // Floating UI's React bindings (under every Base UI tooltip, menu and popover) make the same
  // once-only check as Base UI above: loaded with no global `document`, their layout effects are a
  // no-op, so a popup never positions and its positioner keeps Base UI's `opacity: 0` for the rest
  // of the run. session-info-subagent-card-stays failed so behind session-info-motion in one
  // `bun test` process, and passed alone. Loaded here, after react-dom, which it imports: the copy
  // Base UI itself resolves (a dependency of @base-ui/react, not of this package).
  await import(Bun.resolveSync("@floating-ui/react-dom", Bun.resolveSync("@base-ui/react/tooltip", import.meta.path)));
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
}

// Floating UI (under Base UI's menus and popovers) tests `value instanceof Element` against the
// global before it asks the node's own window, so a file that installs only `window` and
// `document` fails with "Element is not defined". A global Element from any window is enough: the
// check then falls through to the node's own window.
if (!("Element" in scope)) {
  const { JSDOM } = await import("jsdom");
  scope.Element = new JSDOM("<!doctype html>").window.Element;
}

// The agent pane reads its strings from window.__cmuxPaneStrings, which the shipped pane loads from
// locales/<code>.js before its module runs (acpmux/i18n.ts). Tests get the whole table.
{
  const table = (await import("../src/agent-session/acpmux/generated/strings.json")).default;
  (scope as { __cmuxPaneStrings?: unknown }).__cmuxPaneStrings ??= table;
}

// WebKit's Element.getAnimations is missing in jsdom. Base UI ScrollArea (ui/ScrollArea.tsx) asks the viewport for
// its running animations. jsdom builds each window's Element interface through this installer, so wrapping it gives
// every window a test file creates the method, returning no animations, as an idle WebKit view would. A test that
// needs animations installs its own (transcript.test.tsx does).
{
  const { createRequire } = await import("node:module");
  const { dirname, join } = await import("node:path");
  const require = createRequire(import.meta.url);
  // The package exports no subpaths: load the generated interface by its file path, the module jsdom itself loads.
  const root = dirname(require.resolve("jsdom/package.json"));
  const element = require(join(root, "lib/generated/idl/Element.js")) as {
    install: (globalObject: Record<string, { prototype: Record<string, unknown> }>, names: unknown) => void;
  };
  const install = element.install;
  element.install = (globalObject, names) => {
    install(globalObject, names);
    globalObject.Element.prototype.getAnimations ??= () => [];
  };
  // With getAnimations present, Base UI popups would wait for animation frames before closing; jsdom has no
  // animations, so keep Base UI's own test switch on and popups close at once, as they did before the shim.
  (scope as { BASE_UI_ANIMATIONS_DISABLED?: boolean }).BASE_UI_ANIMATIONS_DISABLED = true;
}

// Chromium launches run the system Google Chrome, not Playwright's bundled Chromium, which lacks
// recent security fixes and runs unsandboxed (support/systemChrome.ts says why). Every file shares
// playwright's one `chromium` object, so wrapping it here covers each launch.
// On a Mac outside GitHub Actions no Playwright engine launches at all, system Chrome included (no
// Playwright on Macs, Lawrence 2026-11-02; support/systemChrome.ts says why).
{
  const { refusePlaywrightOnMacs, useSystemChrome } = await import("./support/systemChrome");
  const { chromium, firefox, webkit } = await import("playwright");
  useSystemChrome(chromium as unknown as Parameters<typeof useSystemChrome>[0]);
  refusePlaywrightOnMacs([chromium, webkit, firefox]);
}

// Cross-file leaks: a test file that leaves module state, a timer, a listener or a global behind
// for the next file fails, naming what it left (support/leakDetector.ts says how).
{
  const { installLeakDetector } = await import("./support/leakDetector");
  installLeakDetector();
}
