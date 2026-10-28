// The new chat's composer is the chat's composer (Leo 2026-10-25: "what is going on with the composer
// area in the Command I section? Like, why is that a different style from everything else? It's just
// kind of strange."). Cmd-I's new chat drew the location strip as a tab joined to the card, which
// squared the card's top corners and drew one rim round both, and a sentence over it ("New chats in
// this workspace start in a private folder. Choose Folder…"). Now (agent-pane.new-chat-composer):
//   - the new chat's card is the started chat's: the same component, the same four corners and the
//     same rim, Claude's look and Codex's;
//   - the folder and computer chips stand over the card, apart from it;
//   - no private-folder sentence stands over the composer: the folder chip's menu says it, and its
//     Choose folder… asks the host's workspace folder sheet (`workspace.chooseFolder`), as the
//     sentence's link did;
//   - the folder and computer are the location strip's chips, as the New Tab's composer draws them:
//     the same controls and the same size (Claude's New Tab draws them in its quiet row under the
//     box, #24519);
//   - the first send still carries the prompt and a pasted attachment.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Card = {
  component: string | null;
  /// The strip and the card are the Composer's own children, the card the one ComposerBox draws.
  nested: boolean;
  radii: string[];
  ring: string;
  strip: { bottom: number } | null;
  top: number;
  sentence: boolean;
};

await requireBrowserLane("new-chat-composer.test.ts", async () => {
  const ENTRY = "agent-pane.new-chat-composer";
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-chat-composer: skipping (run `bunx playwright install chromium`)");
    describe.skip("new chat composer", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "claude" } });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "minimal-default" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 720, height: 640 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(
      () => {
        const ready = document.documentElement.dataset.galleryReady;
        return ready === "1" || ready === "error";
      },
      undefined,
      { timeout: 90_000 },
    );
    await page.locator(".acpmux-composer-box").waitFor();
    return page;
  };

  /** Runs in the page: the composer's card, the strip over it and any sentence over the composer. */
  function measure(): Card {
    // The prompt's focus tone is no part of the card's look: measure both cards at rest.
    (document.activeElement as HTMLElement | null)?.blur();
    const box = document.querySelector<HTMLElement>(".acpmux-composer-box")!;
    const style = getComputedStyle(box);
    const strip = document.querySelector(".acpmux-composer-strip")?.getBoundingClientRect();
    const form = box.closest("form");
    return {
      component: form?.getAttribute("data-cmux-component") ?? null,
      nested:
        box.parentElement === form &&
        box.classList.contains("ui-glass") &&
        (document.querySelector(".acpmux-composer-strip")?.parentElement ?? form) === form,
      radii: [
        style.borderTopLeftRadius,
        style.borderTopRightRadius,
        style.borderBottomRightRadius,
        style.borderBottomLeftRadius,
      ],
      // The card's own rim: a strip joined to it moved the rim onto a layer over both.
      ring: style.boxShadow,
      strip: strip ? { bottom: strip.bottom } : null,
      top: box.getBoundingClientRect().top,
      sentence: document.querySelector(".acpmux-folder-choice") !== null,
    };
  }

  const card = async (variant: string): Promise<Card> => {
    const page = await open(variant);
    const measured = await page.evaluate(measure);
    await page.close();
    return measured;
  };

  for (const variant of ["claude", "project", "remote"])
    test(`${variant}: the new chat's card is the started chat's card`, async () => {
      const started = await card("started");
      const fresh = await card(variant);
      expect(fresh.component).toBe("Composer");
      expect(started.component).toBe("Composer");
      expect(fresh.nested).toBe(true);
      expect(fresh.radii).toEqual(started.radii);
      expect(fresh.radii.every((radius) => parseFloat(radius) > 0)).toBe(true);
      expect(fresh.ring).toBe(started.ring);
      // The chips stand over the card, apart from it: no tab on its top edge.
      expect(fresh.strip).not.toBeNull();
      expect(fresh.top - fresh.strip!.bottom).toBeGreaterThanOrEqual(2);
      expect(fresh.top - fresh.strip!.bottom).toBeLessThanOrEqual(10);
    });

  // Codex's look keeps its tray (composerLook.css); the card over it is the started Codex chat's.
  test("codex: the card keeps its four corners and its rim over the tray", async () => {
    const started = await card("started-codex");
    const fresh = await card("codex");
    expect(fresh.component).toBe("Composer");
    expect(fresh.nested).toBe(true);
    expect(fresh.radii).toEqual(started.radii);
    expect(fresh.ring).toBe(started.ring);
  });

  /** Runs in the page: the strip's chips (folder, computer) and where they stand over `card`. */
  function chips(card: string) {
    const strip = document.querySelector(".acpmux-composer-strip")!;
    const box = document.querySelector(card)!.getBoundingClientRect();
    const buttons = [...strip.querySelectorAll<HTMLElement>(".acpmux-location-button")].slice(0, 2);
    return {
      labels: buttons.map((button) => button.getAttribute("aria-label")?.split(":")[0] ?? ""),
      heights: buttons.map((button) => button.getBoundingClientRect().height),
      fonts: buttons.map((button) => {
        const style = getComputedStyle(button);
        return `${style.fontSize} ${style.fontWeight} ${style.color}`;
      }),
      gap: box.top - strip.getBoundingClientRect().bottom,
      /// How far under the card the chips start (the quiet row's strip draws no box of its own).
      below: Math.min(...buttons.map((button) => button.getBoundingClientRect().top)) - box.bottom,
      footer: strip.closest(".nt-foot") !== null,
      filled: getComputedStyle(strip).backgroundColor !== "rgba(0, 0, 0, 0)",
    };
  }

  test("the folder and computer are the New Tab composer's chips", async () => {
    const page = await open("claude");
    const chat = await page.evaluate(chips, ".acpmux-composer-box");
    await page.close();
    const tab = await browser!.newPage({ viewport: { width: 720, height: 640 } });
    await tab.goto(
      `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.new-tab", { variant: "minimal-default" })}`,
    );
    await tab.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await tab.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    const newTab = await tab.evaluate(chips, ".nt-box");
    await tab.close();
    // The computer is "Computer", or "Environment" with preview features on: the same on both.
    expect(chat.labels[0]).toBe("Folder");
    expect(chat.labels).toHaveLength(2);
    expect(newTab.labels).toEqual(chat.labels);
    expect(chat.heights).toEqual(newTab.heights);
    expect(chat.fonts).toEqual(newTab.fonts);
    expect(chat.filled).toBe(false);
    expect(newTab.filled).toBe(false);
    // The chat's chips stand a few px over its card. Claude's New Tab puts them in its one quiet
    // row under the box, before the mode and model (#24519, Leo 2026-10-27: "one single row").
    expect(chat.gap).toBeGreaterThanOrEqual(2);
    expect(chat.gap).toBeLessThanOrEqual(10);
    expect(newTab.footer).toBe(true);
    expect(newTab.below).toBeGreaterThanOrEqual(0);
  });

  test("no private-folder sentence over the composer; the folder chip's menu says it", async () => {
    expect((await card("claude")).sentence).toBe(false);
    const page = await open("folder-menu");
    const menu = await page.evaluate(() => ({
      note: document.querySelector(".acpmux-location-menu .acpmux-location-note")?.textContent?.trim() ?? null,
      choose: document.querySelector('.acpmux-location-menu [data-choose=""]')?.textContent?.trim() ?? null,
      sentence: document.querySelector(".acpmux-folder-choice") !== null,
    }));
    await page.close();
    expect(menu).toEqual({
      note: "New chats in this workspace start in a private folder.",
      choose: "Choose folder…",
      sentence: false,
    });
  });

  test("a chat in a project has no private-folder note in its folder menu", async () => {
    const page = await open("project");
    await page.locator('.acpmux-composer-strip [aria-label="Folder"]').click();
    await page.locator(".acpmux-location-menu").waitFor();
    const note = await page.evaluate(() => document.querySelector(".acpmux-location-menu .acpmux-location-note"));
    await page.close();
    expect(note).toBeNull();
  });

  test("the folder chip's Choose folder… asks the host's workspace folder sheet", async () => {
    const page = await open("choose-folder");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      calls: (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog.map(({ method }) => method),
    }));
    await page.close();
    expect(playFailures(result.report)).toEqual([]);
    expect(result.calls).toContain("workspace.chooseFolder");
    expect(result.calls).not.toContain("project.browse");
  });

  test("a real pointer click on Choose folder asks the workspace sheet once", async () => {
    const page = await open("folder-menu");
    await page.locator('.acpmux-location-menu [data-choose=""]').click();
    await page.waitForFunction(() =>
      (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog.some(
        ({ method }) => method === "workspace.chooseFolder",
      ),
    );
    const count = await page.evaluate(
      () =>
        (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog.filter(
          ({ method }) => method === "workspace.chooseFolder",
        ).length,
    );
    await page.locator(".acpmux-location-menu").waitFor({ state: "hidden" });
    await page.close();
    expect(count).toBe(1);
  });

  test("the first send carries the prompt and the pasted attachment", async () => {
    const page = await open("first-send");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 60_000,
    });
    const result = await page.evaluate(() => {
      const log = (window as unknown as { cmuxGalleryLog: { method: string; params?: { prompt?: unknown } }[] })
        .cmuxGalleryLog;
      return {
        report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
        prompts: log
          .filter(({ method }) => method === "acpmux session/prompt")
          .map(({ params }) => JSON.stringify(params?.prompt)),
      };
    });
    await page.close();
    expect(playFailures(result.report)).toEqual([]);
    expect(result.prompts).toHaveLength(1);
    expect(result.prompts[0]).toContain("Why does the build fail?");
    expect(result.prompts[0]).toContain("[build] step 40: compiling module 40");
  });
});
