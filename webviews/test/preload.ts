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
