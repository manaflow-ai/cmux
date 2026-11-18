// l10n-allow-file: test fixture labels, not shipped UI.
// The composer's usage ring can show the account's plan usage limits instead of the context
// (Leo, 2026-11-04: "are we able to disable the context thing on the bottom right? i want to be
// able to right click disable it" and "i guess we can turn that into a 5h/weekly usage type thing
// instead as well for some people"). Its right-click picks Context Usage or Plan Usage and hides it;
// in plan mode it draws the window closest to its cap and its card is the plan usage popover, read
// only from what the harness reported (acpmux `usageLimits`), never a made-up 0%.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxUsageLimits } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
  });
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  settings.registerComposerRingHost(undefined);
  settings.registerComposerHost(undefined);
  settings.setComposerSettings({ showContextUsage: true, composerRing: "context" });
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

// Leo's Claude desktop screenshot: 5-hour 22% resetting tonight, weekly 41% resetting Monday.
const NOW = Date.UTC(2026, 10, 4, 3, 0);
const claude: AcpmuxUsageLimits = {
  windows: [
    { id: "session", usedPercent: 22, resetsAt: NOW / 1000 + 5 * 3600 },
    { id: "weekly", usedPercent: 41, resetsAt: NOW / 1000 + 4 * 86_400 },
  ],
};
// Leo's Codex screenshot: Pro plan, weekly 10% left, 56,766 credits.
const codex: AcpmuxUsageLimits = {
  windows: [{ id: "weekly", usedPercent: 90, windowMins: 10080, resetsAt: NOW / 1000 + 2 * 86_400 }],
  plan: "pro",
  credits: { balance: "56766" },
};

async function render(node: ReactNode) {
  await act(async () => {
    root = createRoot(host);
    root.render(node);
  });
}

async function wait(ms = 0) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

async function until(done: () => boolean, capMs = 3000) {
  const deadline = Date.now() + capMs;
  while (!done() && Date.now() < deadline) await wait();
}

const ring = () => host.querySelector<HTMLButtonElement>(".acpmux-context-ring");
const card = () => document.querySelector<HTMLElement>(".acpmux-context-card");
const rightClick = (element: Element) =>
  act(async () =>
    element.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 })),
  );
const menuItems = () => [...document.querySelectorAll<HTMLElement>('[role^="menuitem"]')];
const itemText = (entry: HTMLElement) => entry.textContent?.replace("✓", "").trim();
const item = (label: string) => menuItems().find((entry) => itemText(entry) === label);

test("acpmux's usageLimits keep Codex's plan, credits and window length; nothing reported is nothing", async () => {
  const { usageLimitsOf } = await import("../src/agent-session/acpmux/usageLimits");
  expect(
    usageLimitsOf({
      windows: [{ id: "weekly", usedPercent: 90, windowMins: 10080, resetsAt: 1_790_000_000 }],
      plan: "pro",
      credits: { balance: "56766" },
    }),
  ).toEqual({
    windows: [{ id: "weekly", usedPercent: 90, windowMins: 10080, resetsAt: 1_790_000_000 }],
    plan: "pro",
    credits: { balance: "56766" },
  });
  expect(usageLimitsOf({ windows: [], credits: { unlimited: true } })).toEqual({
    windows: [],
    credits: { unlimited: true },
  });
  expect(usageLimitsOf({ windows: [] })).toBeUndefined();
  expect(usageLimitsOf({ windows: [], plan: "pro" })).toBeUndefined();
  expect(usageLimitsOf(null)).toBeUndefined();
});

test("the popover names windows and reset times as the references do", async () => {
  const { planWindowName, planResetLabel, planCreditsLabel, planName, planUsageUrl, planUsedFraction } =
    await import("../src/agent-session/acpmux/usageLimits");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  expect(planWindowName({ id: "session", usedPercent: 1 }, translate)).toBe("5-hour limit");
  expect(planWindowName({ id: "weekly", usedPercent: 1 }, translate)).toBe("Weekly limit");
  expect(planWindowName({ id: "60m", usedPercent: 1, windowMins: 60 }, translate)).toBe("1-hour limit");
  expect(planWindowName({ id: "primary", usedPercent: 1 }, translate)).toBe("Limit");
  expect(planResetLabel(claude.windows[0]!, translate, NOW, "en-US")).toMatch(/^Resets at \d{1,2}:\d{2}\s?[AP]M$/);
  expect(planResetLabel(claude.windows[1]!, translate, NOW, "en-US")).toMatch(
    /^Resets (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2}:\d{2}\s?[AP]M$/,
  );
  expect(planResetLabel({ id: "weekly", usedPercent: 1 }, translate, NOW)).toBeUndefined();
  expect(planCreditsLabel({ balance: "56766" }, translate, "en-US")).toBe("56,766 credits");
  expect(planCreditsLabel({ unlimited: true }, translate)).toBe("Unlimited");
  expect(planName("pro")).toBe("Pro");
  expect(planUsageUrl("claude")).toBe("https://claude.ai/settings/usage");
  expect(planUsageUrl("codex")).toBe("https://chatgpt.com/codex/settings/usage");
  expect(planUsageUrl("opencode")).toBeUndefined();
  expect(planUsedFraction(claude)).toBe(0.41);
  expect(planUsedFraction({ windows: [], credits: { unlimited: true } })).toBeUndefined();
});

test("in plan mode the ring draws the window closest to its cap and opens the plan usage card", async () => {
  const { ContextRing } = await import("../src/agent-session/acpmux/ComposerPickers");
  await render(<ContextRing used={10_000} size={200_000} plan={{ limits: codex, family: "codex" }} now={() => NOW} />);
  expect(ring()!.getAttribute("aria-label")).toBe("Plan usage: 90% used");
  expect(ring()!.disabled).toBe(false);
  await act(async () => ring()!.click());
  await until(() => card() !== null);
  const text = card()!.textContent ?? "";
  expect(text).toContain("Plan usage limits · Pro");
  expect(text).toContain("Weekly limit");
  expect(text).toContain("90%");
  expect(text).toContain("56,766 credits");
  expect(text).toContain("See all");
  // The context card's own lines are not in it.
  expect(card()!.querySelector(".acpmux-context-card-line")).toBeNull();
});

test("in plan mode with no limit reported the ring stays on the context, never a 0%", async () => {
  const { ContextRing } = await import("../src/agent-session/acpmux/ComposerPickers");
  await render(<ContextRing used={50_000} size={200_000} plan={{ family: "codex" }} />);
  expect(ring()!.getAttribute("aria-label")).toBe("25% of context used");
});

test("each popover look reads the same report; none says nothing was reported", async () => {
  const { PlanUsageCardBody } = await import("../src/agent-session/acpmux/PlanUsageCard");
  const bars = renderToStaticMarkup(
    <PlanUsageCardBody limits={claude} family="claude" look="claude-bars" now={() => NOW} />,
  );
  expect(bars).toContain("Plan usage limits");
  expect(bars).toContain("5-hour limit");
  expect(bars).toContain("22%");
  expect(bars).toContain("41%");
  expect(bars.match(/<progress/g)?.length).toBe(2);
  const rows = renderToStaticMarkup(
    <PlanUsageCardBody limits={codex} family="codex" look="codex-rows" now={() => NOW} />,
  );
  expect(rows).toContain("Usage source: Your Pro plan");
  expect(rows).toContain("10% left");
  expect(rows).toContain("Manage usage");
  expect(rows).not.toContain("<progress");
  const compact = renderToStaticMarkup(
    <PlanUsageCardBody limits={claude} family="claude" look="compact" now={() => NOW} />,
  );
  expect(compact).toContain("5-hour limit");
  expect(compact.match(/<progress/g)?.length).toBe(2);
  // A harness with no known usage page gets no link.
  expect(
    renderToStaticMarkup(<PlanUsageCardBody limits={claude} family="opencode" look="claude-bars" />),
  ).not.toContain("See all");
  const none = renderToStaticMarkup(<PlanUsageCardBody look="claude-bars" />);
  expect(none).toContain("No plan usage reported yet");
  expect(none).not.toContain("0%");
});

test("the ring's right-click picks Context Usage or Plan Usage, and hides it", async () => {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  const { UsageRingMenu } = await import("../src/agent-session/acpmux/composerChrome");
  const { ContextRing } = await import("../src/agent-session/acpmux/ComposerPickers");
  const writes: [string, unknown][] = [];
  settings.registerComposerRingHost((ring) => void writes.push(["pane.setComposerRing", { ring }]));
  settings.registerComposerHost((method, show) => void writes.push([method, { show }]));
  function Ring() {
    const { composerRing, showContextUsage } = settings.useComposerSettings();
    if (!showContextUsage) return null;
    return (
      <UsageRingMenu>
        <ContextRing
          used={10_000}
          size={200_000}
          {...(composerRing === "planUsage" ? { plan: { limits: claude, family: "claude" } } : {})}
        />
      </UsageRingMenu>
    );
  }
  await render(<Ring />);
  expect(ring()!.getAttribute("aria-label")).toBe("5% of context used");
  await rightClick(ring()!);
  expect(menuItems().map(itemText)).toEqual(["Context Usage", "Plan Usage", "Hide Usage Ring"]);
  expect(item("Context Usage")!.getAttribute("aria-checked")).toBe("true");
  await act(async () => item("Plan Usage")!.click());
  expect(settings.composerSettingsSnapshot().composerRing).toBe("planUsage");
  expect(writes).toContainEqual(["pane.setComposerRing", { ring: "planUsage" }]);
  await until(() => ring()?.getAttribute("aria-label") === "Plan usage: 41% used");
  expect(ring()!.getAttribute("aria-label")).toBe("Plan usage: 41% used");
  await rightClick(ring()!);
  await act(async () => item("Hide Usage Ring")!.click());
  expect(ring()).toBeNull();
  expect(writes).toContainEqual(["pane.showContextUsage", { show: false }]);
});

test("the host's composer value carries the ring's mode; anything else is the context", async () => {
  const { readComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  expect(readComposerSettings({ composerRing: "planUsage" }).composerRing).toBe("planUsage");
  expect(readComposerSettings({ composerRing: "weekly" }).composerRing).toBe("context");
  expect(readComposerSettings({}).composerRing).toBe("context");
});

test("Session Info's Usage lists the plan's limits only when reported", async () => {
  const { usageSection } = await import("../src/agent-session/acpmux/session-info/native/usage");
  const { NativeInfoActions } = await import("../src/agent-session/acpmux/session-info/native/model");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const section = usageSection(
    { planLimits: codex, sessions: [], open: true, locale: "en-US" },
    new NativeInfoActions(),
    translate,
  );
  const rows = section!.rows.map((row) => [row.id, row.title, row.trailing]);
  expect(rows[0]).toEqual(["plan", "Plan limits", undefined]);
  expect(rows[1]![0]).toBe("plan:weekly");
  expect(rows[1]![2]).toMatch(/^90% · Resets /);
  expect(rows[2]).toEqual(["plan:credits", "Credits", "56,766 credits"]);
  expect(usageSection({ sessions: [], open: true }, new NativeInfoActions(), translate)).toBeUndefined();
});

test("an inert ring (no usage reported yet) still opens its right-click, and a click does nothing", async () => {
  const { UsageRingMenu } = await import("../src/agent-session/acpmux/composerChrome");
  const { ContextRing } = await import("../src/agent-session/acpmux/ComposerPickers");
  await render(
    <UsageRingMenu>
      <ContextRing />
    </UsageRingMenu>,
  );
  // aria-disabled, not disabled: WebKit sends no contextmenu to a disabled button.
  expect(ring()!.disabled).toBe(false);
  expect(ring()!.getAttribute("aria-disabled")).toBe("true");
  // act flushes the click's state update, so an opened card would already be in the DOM.
  await act(async () => ring()!.click());
  expect(card()).toBeNull();
  await rightClick(ring()!);
  expect(menuItems().map(itemText)).toEqual(["Context Usage", "Plan Usage", "Hide Usage Ring"]);
});
