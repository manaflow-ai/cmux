// l10n-allow-file: test fixture prompts, PR titles and subagent names, not shipped UI.
// The wheel in the gutters of the floating bottom stack scrolls the transcript (Leo 2026-10-20: "if
// it's not in the composer it should just scroll"), beside every part of it, not only the composer's
// card: most parts are bands the pane's width wide whose card or bar is inset in them, and the
// band passes the pointer through to the transcript under it. What the part draws still takes the
// pointer, and the wheel over it scrolls nothing (the stack is a no-scroll zone). (bottomStack.css,
// wheelPassThrough.ts)
//
// One chat with every part the stack can show at once: a question waiting for an answer (the asks
// stack), the pull request dock (three PRs), an error card (the chat menu's Edit CLAUDE.md, which
// the browser host refuses), the tray of running work (two subagents), the queued prompts and the
// composer's card; then the dictation notice in the error card's place (the mic, which the browser
// host refuses too). The page is the pane's dev entry with its browser host, talking JSON-RPC to a
// stand-in acpmux (support/papercutChat.ts). Real Chromium and WebKit (the app's engine) with real
// wheel events; CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/agent-pane-dock-gutters.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane, type PapercutStep } from "./support/papercutChat";

await requireBrowserLane("agent-pane-dock-gutters.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-dock-gutters: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("dock gutters", () => test("browsers", () => {}));
    return;
  }

  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  const pullRequest = (id: string, title: string, number: number): PapercutStep[] => {
    const command = `gh pr create --title "${title}" --body x`;
    return [
      [
        "in",
        "tool_call",
        update({
          sessionUpdate: "tool_call",
          toolCallId: id,
          title: command,
          kind: "execute",
          status: "in_progress",
          rawInput: { command },
        }),
      ],
      [
        "in",
        "tool_call_update",
        update({
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          content: [
            { type: "content", content: { type: "text", text: `https://github.com/acme/uploader/pull/${number}\n` } },
          ],
          rawOutput: { exit_code: 0 },
        }),
      ],
    ];
  };
  const spawned = (id: string, name: string): PapercutStep => [
    "in",
    "subagent_spawned",
    update({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id, parent: null, name, state: "running" }] }),
  ];
  const extra: PapercutStep[] = [
    ...pullRequest("pr1", "Add retry to the uploader", 41),
    ...pullRequest("pr2", "Cover retry with a test", 42),
    ...pullRequest("pr3", "Document retry", 43),
    spawned("a1", "Reviewer"),
    spawned("a2", "Tester"),
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "merge",
        title: "gh pr merge 41",
        kind: "execute",
        status: "pending",
        rawInput: { command: "gh pr merge 41" },
      }),
    ],
    [
      "mux",
      "permission_request",
      {
        permissionId: "p1",
        request: {
          toolCall: { toolCallId: "merge", title: "gh pr merge 41", kind: "execute" },
          options: [
            { optionId: "allow", name: "Allow", kind: "allow_once" },
            { optionId: "deny", name: "Deny", kind: "reject_once" },
          ],
        },
      },
    ],
  ];
  const queue = ["first", "second"].map((prompt, index) => ({
    promptId: `q-${index + 1}`,
    prompt: `${prompt} queued prompt`,
  }));

  const browsers = new Map<string, Browser>();
  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    pane = await papercutPane(() => current!, {
      turns: 60,
      running: true,
      extra,
      session: { steering: true, queuePaused: false, queued: queue.length, queue },
      // The chat's end is the running turn's calls; the stack's last part to arrive is the tray.
      ready: ".acpmux-running-tray",
    });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  const scrollTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);

  /// Wheels `deltaY` with the pointer at (`x`, `y`), and the scroll of the transcript it made. Counts
  /// painted frames: once the transcript or a part of the stack moved, it waits until they hold still
  /// for 12 frames, so the next wheel measures only its own scroll; when nothing moved in 30 frames,
  /// the wheel scrolled nothing.
  async function wheelAt(page: Page, x: number, y: number, deltaY: number): Promise<number> {
    await page.mouse.move(x, y);
    const before = await scrollTop(page);
    await page.mouse.wheel(0, deltaY);
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const scrollers = [
            document.querySelector<HTMLElement>(".acpmux-scroll")!,
            ...document.querySelectorAll<HTMLElement>(".acpmux-main > .acpmux-dock *"),
          ];
          const read = () => scrollers.map((node) => node.scrollTop).join(",");
          const start = read();
          let last = start;
          let frames = 0;
          let still = 0;
          // Reads scroll offsets only (no layout under test), to count the frames a scroll holds still.
          const frame = () => {
            frames++;
            const now = read();
            still = now === last ? still + 1 : 0;
            last = now;
            const moved = now !== start;
            if ((moved && still >= 12) || (!moved && frames >= 30) || frames >= 600) resolve();
            // raf-read: scroll offsets only, to count frames the transcript and the stack hold still.
            else requestAnimationFrame(frame);
          };
          requestAnimationFrame(frame);
        }),
    );
    return (await scrollTop(page)) - before;
  }

  /// What the pointer reaches at (`x`, `y`): something in the transcript (a row hidden under the
  /// stack), the band of `part` itself, inside `part`, or something else.
  const reaches = (page: Page, x: number, y: number, part: string) =>
    page.evaluate(
      ([x, y, part]) => {
        const hit = document.elementFromPoint(x, y);
        if (hit?.closest(".acpmux-scroll")) return "transcript";
        if (hit?.matches(`.acpmux-main > .acpmux-dock > :is(${part})`)) return "band";
        if (hit?.closest(part)) return "part";
        return hit ? `${hit.tagName.toLowerCase()}.${[...hit.classList].join(".")}` : "nothing";
      },
      [x, y, part] as const,
    );

  /// Where the part's drawn surface (`surface`) shows inside its band (`part`): the gutter point left
  /// of the surface and the surface's middle, both at the surface's vertical middle.
  async function points(page: Page, part: string, surface: string) {
    const band = (await page.locator(`.acpmux-main > .acpmux-dock ${part}`).first().boundingBox())!;
    const card = (await page.locator(`.acpmux-main > .acpmux-dock ${surface}`).first().boundingBox())!;
    const top = Math.max(band.y, card.y);
    const bottom = Math.min(band.y + band.height, card.y + card.height);
    return { band, card, y: (top + bottom) / 2, gutter: card.x - 8, middle: card.x + Math.min(card.width / 2, 24) };
  }

  /// The wheel in the gutter beside `surface` scrolls the transcript either way; the gutter is the
  /// part's band (`reach` "band": it takes the pointer, so a hover, click or drag there never reaches
  /// the rows hidden under the stack) or, beside the composer's card and queue, the transcript. The
  /// surface itself takes the pointer, and the wheel over it moves the transcript not at all.
  async function expectGutter(page: Page, name: string, part: string, surface: string, reach = "band") {
    const { band, card, y, gutter, middle } = await points(page, part, surface);
    // The part is a band with its surface inset: there is a gutter to test.
    expect({ name, inset: card.x - band.x > 12 }).toEqual({ name, inset: true });
    expect({ name, gutter: await reaches(page, gutter, y, part) }).toEqual({ name, gutter: reach });
    expect({ name, surface: await reaches(page, middle, y, part) }).toEqual({ name, surface: "part" });
    const up = await wheelAt(page, gutter, y, -300);
    expect({ name, gutterScrollsUp: up < -100 }).toEqual({ name, gutterScrollsUp: true });
    const down = await wheelAt(page, gutter, y, 300);
    expect({ name, gutterScrollsDown: down > 100 }).toEqual({ name, gutterScrollsDown: true });
    // A wheel that got through moves the transcript 300 px; under 2 px is rows settling mid-history.
    const over = await wheelAt(page, middle, y, -300);
    expect({ name, surfaceScrolls: Math.abs(over) >= 2 }).toEqual({ name, surfaceScrolls: false });
  }

  /// The wheel at (`x`, `y`), in the empty room of a band beside what it holds, scrolls the transcript,
  /// and the pointer there reaches the band, never a row hidden under the stack.
  async function expectEmptyRoom(page: Page, name: string, part: string, x: number, y: number) {
    expect({ name, reach: await reaches(page, x, y, part) }).toEqual({ name, reach: "band" });
    const up = await wheelAt(page, x, y, -300);
    expect({ name, scrollsUp: up < -100 }).toEqual({ name, scrollsUp: true });
    const down = await wheelAt(page, x, y, 300);
    expect({ name, scrollsDown: down > 100 }).toEqual({ name, scrollsDown: true });
  }

  /// A part that is its own box in the stack, inset by its margin (`part`): the stack's gutter beside
  /// it reaches the transcript and the wheel there scrolls it; the box takes the pointer, and the
  /// wheel over it moves the transcript not at all.
  async function expectInsetBox(page: Page, name: string, part: string) {
    const box = (await page.locator(`.acpmux-dock > ${part}`).boundingBox())!;
    const y = box.y + box.height / 2;
    expect({ name, gutter: await reaches(page, box.x - 8, y, part) }).toEqual({ name, gutter: "transcript" });
    expect({ name, box: ["band", "part"].includes(await reaches(page, box.x + 4, y, part)) }).toEqual({
      name,
      box: true,
    });
    const over = await wheelAt(page, box.x + 4, y, -300);
    expect({ name, boxScrolls: Math.abs(over) >= 2 }).toEqual({ name, boxScrolls: false });
    const beside = await wheelAt(page, box.x - 8, y, -300);
    expect({ name, gutterScrollsUp: beside < -100 }).toEqual({ name, gutterScrollsUp: true });
  }

  async function open(height = 1000) {
    const page = await pane!.open({ width: 900, height });
    await page.locator(".acpmux-asks-stack").waitFor({ timeout: 20_000 });
    await page.locator(".acpmux-pr-dock").waitFor({ timeout: 20_000 });
    await page.locator(".acpmux-running-tray").waitFor({ timeout: 20_000 });
    await page.locator(".acpmux-composer-queue").waitFor({ timeout: 20_000 });
    // Up from the latest message, so the transcript can scroll either way.
    expect(await wheelAt(page, 450, 80, -1500)).toBeLessThan(0);
    return page;
  }

  for (const [name] of engines) {
    describe(name, () => {
      test("the gutter beside every part of the stack scrolls the transcript, and the part keeps the pointer", async () => {
        current = browsers.get(name);
        const page = await open();
        // An error card: the browser host refuses to open CLAUDE.md.
        await page.getByRole("button", { name: "Chat actions" }).click();
        await page.locator(".acpmux-chat-menu-item", { hasText: "Edit CLAUDE.md" }).click();
        await page.locator(".acpmux-dock > .acpmux-instructions-notice").waitFor({ timeout: 10_000 });
        await page.mouse.move(450, 80);

        // Every part the stack shows, in its order, so a part missing from the fixture fails here.
        const shown = await page.evaluate(() =>
          [...document.querySelectorAll(".acpmux-main > .acpmux-dock > *")]
            .filter((part) => part.getBoundingClientRect().height > 0)
            .map((part) => part.classList[0]),
        );
        expect(shown).toEqual([
          "acpmux-permission",
          "acpmux-pr-dock",
          "acpmux-host-error",
          "acpmux-running-tray",
          "acpmux-composer",
        ]);

        await expectGutter(page, "question", ".acpmux-asks-stack", ".acpmux-asks-stack > *");
        await expectGutter(page, "pull requests", ".acpmux-pr-dock", ".acpmux-pr-dock > *");
        await expectGutter(
          page,
          "error card",
          ".acpmux-instructions-notice",
          ".acpmux-instructions-notice > .acpmux-host-error-card",
        );
        await expectGutter(
          page,
          "queue",
          ".acpmux-composer",
          ".acpmux-composer > .acpmux-composer-queue",
          "transcript",
        );
        await expectGutter(page, "card", ".acpmux-composer", ".acpmux-composer > .acpmux-composer-box", "transcript");

        // The empty room right of the pull requests' chips. The chips stand in one list, as wide as
        // the widest (#25207), so the room starts at the list's right edge, not a narrower chip's.
        const chip = (await page.locator(".acpmux-pr-dock__chip").first().boundingBox())!;
        const chips = (await page.locator(".acpmux-pr-dock__list").first().boundingBox())!;
        await expectEmptyRoom(page, "right of a chip", ".acpmux-pr-dock", chips.x + chips.width + 16, chip.y + 13);

        // The tray of running work is its own box, inset by its margin: beside it is the stack's own
        // gutter, which passes through as the composer's does, and the tray takes the pointer.
        await expectInsetBox(page, "tray", ".acpmux-running-tray");

        // The error card's own buttons still take a click.
        await page.locator(".acpmux-instructions-notice button[data-notice-action=dismiss]").click();
        await page.locator(".acpmux-instructions-notice").waitFor({ state: "detached", timeout: 10_000 });

        // The dictation notice, an error card that is its own box (inset by its margin).
        await page.locator(".acpmux-mic").first().click();
        await page.locator(".acpmux-dock > .acpmux-dictation-notice").waitFor({ timeout: 10_000 });
        await expectInsetBox(page, "dictation notice", ".acpmux-dictation-notice");
        await page.close();
      });

      // In a short pane the pull request dock and the question card give up height and scroll inside
      // it: the wheel over their rows scrolls only them, and their scrollbar, at the band's edge,
      // takes the pointer (so it can be dragged).
      test("a part that scrolls in a short pane scrolls under the wheel alone, and its scrollbar takes the pointer", async () => {
        current = browsers.get(name);
        const page = await open(440);
        const lists = await page.evaluate(() =>
          [".acpmux-pr-dock", ".acpmux-asks-stack"].filter((selector) => {
            const list = document.querySelector<HTMLElement>(`.acpmux-main > .acpmux-dock > ${selector}`)!;
            return list.scrollHeight > list.clientHeight + 4;
          }),
        );
        expect(lists).toContain(".acpmux-pr-dock");
        for (const list of lists) {
          const band = (await page.locator(`.acpmux-dock > ${list}`).boundingBox())!;
          const y = band.y + band.height / 2;
          // The list's scroll, or a scroller inside it (the permission panel's own).
          const listTop = () =>
            page.evaluate((list) => {
              const band = document.querySelector<HTMLElement>(`.acpmux-dock > ${list}`)!;
              return [band, ...band.querySelectorAll<HTMLElement>("*")].reduce((sum, node) => sum + node.scrollTop, 0);
            }, list);
          // Over its rows, a little in from the card's leading edge.
          const row = (await page.locator(`.acpmux-dock > ${list} > *`).first().boundingBox())!;
          const before = await listTop();
          const moved = await wheelAt(page, row.x + 12, y, 60);
          expect({ list, transcript: Math.abs(moved) < 2 }).toEqual({ list, transcript: true });
          // The pull request dock scrolls under it. The question card's own scrolling is not this
          // file's: the wheel over its rows moves neither it nor the transcript today, as on base.
          if (list === ".acpmux-pr-dock")
            expect({ list, scrolled: (await listTop()) > before }).toEqual({ list, scrolled: true });
          expect({ list, scrollbar: await reaches(page, band.x + band.width - 3, y, list) }).toEqual({
            list,
            scrollbar: "band",
          });
        }
        await page.close();
      });
    });
  }
});
