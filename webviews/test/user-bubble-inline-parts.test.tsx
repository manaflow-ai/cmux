// l10n-allow-file: test fixture prompts, not shipped UI.
// A sent prompt whose attachments sat inline (`inlineParts`) draws them in its bubble in order,
// as Messages does. These pin what the legacy bands already did right: a thumbnail is the whole image
// in its own shape, never a magnified crop (conversation.css; Leo, 2026-11-05: "I don't think we have
// good enough looking previews for these"), a pasted block is part of the message's one text body
// (ask-14d16a6247), and an image's retained original (`companionOf`) is never drawn again as a
// separate file.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const sheet = dom.window.document.createElement("style");
sheet.textContent = readFileSync(
  new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  "utf8",
);
dom.window.document.head.append(sheet);
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  NodeFilter: dom.window.NodeFilter,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { clearImageEntries } = await import("../src/agent-session/acpmux/conversation/imageEntries");
const { ImageViewerContext } = await import("../src/agent-session/acpmux/conversation/imageViewerContext");
const { resetSourceIcons } = await import("../src/agent-session/acpmux/composer/sourceBadgeModel");

const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
const { resetTranscriptDisclosure } =
  await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
const { translate } = await import("../src/agent-session/acpmux/i18n");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
type Row = Parameters<typeof UserBubble>[0]["row"];
const prompt = (id: string, text: string, inlineParts: unknown[]): Row =>
  ({ id, version: 1, at: Date.now(), kind: "user", text, inlineParts }) as Row;
const render = async (
  row: Row,
  reveal?: React.ContextType<typeof FindReveal>,
  promptImage: (id: string) => Promise<string | undefined> = async () => "data:image/png;base64,AA==",
) => {
  await act(async () => {
    root.render(
      <TurnActionsContext.Provider value={{ promptImage }}>
        <ImageViewerContext.Provider value={() => {}}>
          <FindReveal.Provider value={reveal}>
            <UserBubble row={row} text={row.text ?? ""} />
          </FindReveal.Provider>
        </ImageViewerContext.Provider>
      </TurnActionsContext.Provider>,
    );
    for (let index = 0; index < 5; index++) await Promise.resolve();
  });
};

try {
  test("an inline image is the sent thumbnail: the whole image in its own shape", async () => {
    clearImageEntries();
    await render(
      prompt("inline-image", "look at this", [
        { kind: "text", text: "look " },
        { kind: "image", id: "tall", mimeType: "image/png", name: "tall.png", width: 400, height: 1600 },
        { kind: "text", text: " at this" },
      ]),
    );
    const img = host.querySelector<HTMLImageElement>("[data-inline-content] img")!;
    expect(img).not.toBeNull();
    // The same box as the image band above a legacy bubble: the image's own shape, so `cover` crops nothing.
    const [width, height] = img.style.aspectRatio.split("/").map(Number);
    expect(width! / height!).toBe(400 / 1600);
    const button = img.closest("button")!;
    expect(dom.window.getComputedStyle(button).cursor).toBe("zoom-in");
  });

  test("an inline pasted block is part of the message's one body, as the draft read", async () => {
    const pasted = "first pasted line\nsecond pasted line\nthird pasted line";
    await render(
      prompt("inline-paste", `before\n${pasted}\nafter`, [
        { kind: "text", text: "before " },
        { kind: "text", text: pasted, pasted: true },
        { kind: "text", text: " after" },
      ]),
    );
    expect(host.querySelector(".cv-user__paste, .cv-user__pasted")).toBeNull();
    const bodies = host.querySelectorAll("[data-inline-content] .cv-user__typed");
    expect(bodies).toHaveLength(1);
    expect(bodies[0]!.textContent).toBe(`before ${pasted} after`);
  });

  test("an image's retained original is not drawn again as a file", async () => {
    clearImageEntries();
    await render(
      prompt("inline-companion", "shot then words", [
        { kind: "image", id: "shot", mimeType: "image/png", name: "shot.png", blockIndex: 0 },
        { kind: "file", name: "shot-original.heic", uri: "file:///tmp/shot-original.heic", companionOf: 0 },
        { kind: "text", text: "then words" },
      ]),
    );
    expect(host.querySelector("[data-inline-content]")).not.toBeNull();
    expect(host.textContent).not.toContain("shot-original.heic");
  });
  for (const attachmentView of ["inline", "strip"] as const) {
    test(`${attachmentView}: a 2,000-line interleaved prompt folds and toggles without losing its order`, async () => {
      resetTranscriptDisclosure();
      await act(async () => setComposerSettings({ attachmentView }));
      const text = Array.from({ length: 2000 }, (_, index) => `line ${index + 1}`).join("\n");
      await render(
        prompt(`long-${attachmentView}`, `before\n${text}\nafter`, [
          { kind: "text", text: "before\n" },
          { kind: "image", id: "first", mimeType: "image/png", name: "first.png" },
          { kind: "text", text },
          { kind: "image", id: "second", mimeType: "image/png", name: "second.png" },
          { kind: "text", text: "\nafter" },
        ]),
      );
      const body = host.querySelector<HTMLElement>(".cv-user__text")!;
      const toggle = () => host.querySelector<HTMLButtonElement>(".cv-user__more")!;
      const order = () =>
        [...host.querySelectorAll<HTMLElement>("[data-inline-content] > *")].map(
          (node) => node.querySelector("img")?.getAttribute("alt") ?? node.textContent,
        );
      const expected =
        attachmentView === "inline"
          ? ["before\n", "first.png", text, "second.png", "\nafter"]
          : [`before\n${text}\nafter`];
      expect(body.classList.contains("is-clamped")).toBe(true);
      expect(toggle().textContent).toBe(translate("message.more"));
      expect(toggle().getAttribute("aria-controls")).toBe(body.id);
      expect(order()).toEqual(expected);
      if (attachmentView === "strip")
        expect(
          [...host.querySelectorAll("[data-inline-attachment-strip] img")].map((img) => img.getAttribute("alt")),
        ).toEqual(["first.png", "second.png"]);
      await act(async () => toggle().click());
      expect(body.classList.contains("is-clamped")).toBe(false);
      expect(toggle().textContent).toBe(translate("message.less"));
      expect(order()).toEqual(expected);
      await act(async () => toggle().click());
      expect(body.classList.contains("is-clamped")).toBe(true);
      expect(toggle().getAttribute("aria-expanded")).toBe("false");
      expect(order()).toEqual(expected);
      await act(async () => setComposerSettings({ attachmentView: "inline" }));
    });
  }

  test("a long ordered prompt with a paste folds once, with no fold of the paste's own", async () => {
    resetTranscriptDisclosure();
    const text = Array.from({ length: 30 }, (_, index) => `line ${index + 1}`).join("\n");
    await render(
      prompt("long-with-paste", text, [
        { kind: "text", text: "before " },
        { kind: "text", text: "pasted details", pasted: true },
        { kind: "text", text },
      ]),
    );
    const body = host.querySelector(".cv-user__text")!;
    expect(body.classList.contains("is-clamped")).toBe(true);
    expect(host.querySelectorAll("[aria-expanded]")).toHaveLength(1);
    await act(async () => host.querySelector<HTMLButtonElement>(".cv-user__more")!.click());
    expect(body.classList.contains("is-clamped")).toBe(false);
    expect(body.textContent).toContain("before pasted details\nline 1");
  });
  // A prompt whose attachments the composer placed records each one `placed` (inlinePrompt.ts,
  // acpmux hub/prompt_images.rs): it draws where it was put, the last part included, never in the
  // legacy band above the bubble. An unplaced prompt (the old shape: text, pastes, then
  // attachments) records no marker and keeps the band.
  const inlineShape = () =>
    [...host.querySelectorAll<HTMLElement>("[data-inline-content] > *")].map((node) =>
      node.querySelector("img")
        ? `image:${node.querySelector("img")!.getAttribute("alt")}`
        : node.classList.contains("cv-user__pasted")
          ? "apart"
          : node.textContent,
    );
  test("inline: a placed trailing image sits after its text inside the bubble", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "inline" }));
    await render({
      ...prompt("trailing-image", "look at this", [
        { kind: "text", text: "look at this" },
        { kind: "image", id: "trail", mimeType: "image/png", name: "trail.png", placed: true },
      ]),
      images: [{ id: "trail", mimeType: "image/png", name: "trail.png" }],
    });
    expect(host.querySelector(".cv-user__images")).toBeNull();
    expect(inlineShape()).toEqual(["look at this", "image:trail.png"]);
  });
  test("inline: a placed prompt's text reads as a legacy prompt's does, Markdown and all", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "inline" }));
    await render(
      prompt("markdown-order", "see **this** one", [
        { kind: "text", text: "see **this**" },
        { kind: "image", id: "md", mimeType: "image/png", name: "md.png", placed: true },
        { kind: "text", text: "one" },
      ]),
    );
    const content = host.querySelector("[data-inline-content]")!;
    // The shared prompt renderer (PromptText.tsx PromptTyped): no literal asterisks in the bubble.
    expect(content.querySelector(".cv-user__markdown strong")?.textContent).toBe("this");
    expect(content.textContent).not.toContain("**");
    expect(content.querySelector(".cv-user__typed")?.textContent).toBe("one");
  });
  test("inline: a placed leading paste then a trailing image keep their order", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "inline" }));
    const pasted = "pasted line one\npasted line two";
    await render({
      ...prompt("paste-then-image", pasted, [
        { kind: "pasted", name: "Pasted text", text: pasted, placed: true },
        { kind: "image", id: "after-paste", mimeType: "image/png", name: "after-paste.png", placed: true },
      ]),
      images: [{ id: "after-paste", mimeType: "image/png", name: "after-paste.png" }],
    });
    expect(host.querySelector(".cv-user__images")).toBeNull();
    expect(inlineShape()).toEqual([pasted, "image:after-paste.png"]);
  });
  test("inline: a placed prompt draws the same before and after acpmux echoes it", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "inline" }));
    const pasted = "a long paste\nof two lines";
    const text = `see this\n${pasted}`;
    // This pane's own row, before the echo (direct.ts): the composer's parts, its image's bytes.
    await render({
      ...prompt("placed-send", text, [
        { kind: "text", text: "see this" },
        { kind: "pasted", attachmentId: "paste", name: "Pasted text", text: pasted, placed: true },
        {
          kind: "image",
          id: "shot",
          attachmentId: "shot",
          mimeType: "image/png",
          name: "shot.png",
          src: "data:image/png;base64,AA==",
          placed: true,
        },
      ]),
      pasted: [{ start: 9, end: text.length }],
      images: [{ id: "shot", mimeType: "image/png", name: "shot.png", src: "data:image/png;base64,AA==" }],
    });
    expect(host.querySelector(".cv-user__images")).toBeNull();
    const before = inlineShape();
    // One body: the paste went in right after the typed words, so it starts on the next line.
    expect(before).toEqual([`see this\n${pasted}`, "image:shot.png"]);
    // acpmux's echo: the same parts by its own ids, each still placed.
    await render({
      ...prompt("placed-send", text, [
        { kind: "text", text: "see this" },
        { kind: "pasted", name: "Pasted text", text: pasted, placed: true },
        { kind: "image", id: "durable-shot", mimeType: "image/png", name: "shot.png", placed: true },
      ]),
      pasted: [{ start: 9, end: text.length }],
      images: [{ id: "durable-shot", mimeType: "image/png", name: "shot.png" }],
    });
    expect(host.querySelector(".cv-user__images")).toBeNull();
    expect(inlineShape()).toEqual(before);
  });
  test("inline: an unplaced text then image keeps the legacy band above the bubble", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "inline" }));
    await render({
      ...prompt("unplaced", "what is this", [
        { kind: "text", text: "what is this" },
        { kind: "image", id: "strip-shot", mimeType: "image/png", name: "strip-shot.png" },
      ]),
      images: [{ id: "strip-shot", mimeType: "image/png", name: "strip-shot.png" }],
    });
    expect(host.querySelectorAll(".cv-user__images img")).toHaveLength(1);
    expect(host.querySelector("[data-inline-content]")).toBeNull();
    expect(host.querySelector(".cv-user__bubble")?.textContent).toBe("what is this");
  });

  test("inline: a placed prompt keeps its unplaced strip image in the band, not in the text", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "inline" }));
    await render({
      ...prompt("mixed", "look here", [
        { kind: "text", text: "look" },
        { kind: "image", id: "placed-shot", mimeType: "image/png", name: "placed-shot.png", placed: true },
        { kind: "text", text: "here" },
        { kind: "image", id: "strip-shot", mimeType: "image/png", name: "strip-shot.png" },
      ]),
      images: [
        { id: "placed-shot", mimeType: "image/png", name: "placed-shot.png" },
        { id: "strip-shot", mimeType: "image/png", name: "strip-shot.png" },
      ],
    });
    expect(inlineShape()).toEqual(["look", "image:placed-shot.png", "here"]);
    expect(
      [...host.querySelectorAll("[data-inline-attachment-strip] img")].map((img) => img.getAttribute("alt")),
    ).toEqual(["strip-shot.png"]);
  });

  test("inline: a placed image draws from its own bytes before acpmux knows it", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "inline" }));
    const src = "data:image/png;base64,iVBORw0KGgo=";
    // This pane's own row, before the echo: the composer's id, which acpmux cannot read yet.
    await render(
      prompt("placed-local", "look here", [
        { kind: "text", text: "look" },
        { kind: "image", id: "composer-shot", mimeType: "image/png", name: "local.png", src, placed: true },
        { kind: "text", text: "here" },
      ]),
      undefined,
      async () => undefined,
    );
    expect(inlineShape()).toEqual(["look", "image:local.png", "here"]);
    expect(host.querySelector("[data-inline-content] img")?.getAttribute("src")).toBe(src);
  });

  // A placed prompt that is a text file alone, with nothing typed: its body went as a text block,
  // and the bubble shows its file chip, as every attachment keeps its chip (ask-14d16a6247).
  for (const attachmentView of ["inline", "strip"] as const)
    test(`${attachmentView}: a placed text file with no typed text shows its file chip`, async () => {
      clearImageEntries();
      resetTranscriptDisclosure();
      await act(async () => setComposerSettings({ attachmentView }));
      try {
        const body = "notes.txt\n```\nfirst line\nsecond line\n```";
        await render(
          prompt(`text-file-${attachmentView}`, body, [
            { kind: "file", name: "notes.txt", mimeType: "text/plain", size: 22, text: body, placed: true },
          ]),
        );
        expect(host.querySelector(".cv-user__bubble .cv-user__paste, .cv-user__bubble .cv-user__pasted")).toBeNull();
        const chip = host.querySelector(".cv-user__bubble .acpmux-file-chip");
        expect(chip).not.toBeNull();
        expect(chip!.textContent).toContain("notes.txt");
      } finally {
        await act(async () => setComposerSettings({ attachmentView: "inline" }));
      }
    });

  // Two files of one name from two folders: each is the shared file chip (FileAttachment.tsx), with
  // its size and its whole path as its tooltip, so the two read apart, in both views.
  for (const attachmentView of ["inline", "strip"] as const)
    test(`${attachmentView}: same-named placed files show their sizes and full paths`, async () => {
      clearImageEntries();
      resetTranscriptDisclosure();
      await act(async () => setComposerSettings({ attachmentView }));
      try {
        await render(
          prompt(`same-name-${attachmentView}`, "compare these", [
            { kind: "text", text: "compare these" },
            {
              kind: "file",
              name: "config.json",
              mimeType: "application/json",
              size: 2048,
              uri: "file:///Users/sample/app/config.json",
              placed: true,
            },
            {
              kind: "file",
              name: "config.json",
              mimeType: "application/json",
              size: 5 * 1024 * 1024,
              uri: "file:///Users/sample/server/config.json",
              placed: true,
            },
          ]),
        );
        const scope = attachmentView === "inline" ? "[data-inline-content]" : "[data-inline-attachment-strip]";
        const chips = [...host.querySelectorAll<HTMLElement>(`${scope} .acpmux-file-chip`)];
        expect(chips.map((chip) => chip.getAttribute("title"))).toEqual([
          "/Users/sample/app/config.json",
          "/Users/sample/server/config.json",
        ]);
        expect(chips.map((chip) => chip.querySelector(".acpmux-file-chip__size")?.textContent)).toEqual([
          "2 kB",
          "5 MB",
        ]);
        expect(chips.every((chip) => chip.getAttribute("data-file-type") === "json")).toBe(true);
      } finally {
        await act(async () => setComposerSettings({ attachmentView: "inline" }));
      }
    });

  // acpmux records a prompt's text blocks joined by a newline (hub/session.rs prompt_text): the
  // strip view's bubble, with the image moved to the band, reads that text, not "beforeafter".
  test("strip: the bubble keeps the separator between text blocks an image stood between", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "strip" }));
    try {
      await render(
        prompt("strip-separators", "before\nafter", [
          { kind: "text", text: "before" },
          { kind: "image", id: "between", mimeType: "image/png", name: "between.png" },
          { kind: "text", text: "after" },
        ]),
      );
      expect(
        [...host.querySelectorAll("[data-inline-attachment-strip] img")].map((img) => img.getAttribute("alt")),
      ).toEqual(["between.png"]);
      expect(host.querySelector(".cv-user__text")?.textContent).toBe("before\nafter");
    } finally {
      await act(async () => setComposerSettings({ attachmentView: "inline" }));
    }
  });

  test("Find in an ordered paste opens the message's one fold", async () => {
    resetTranscriptDisclosure();
    const text = Array.from({ length: 30 }, (_, index) => `line ${index + 1}`).join("\n");
    await render(
      prompt("ordered-paste-find", text, [
        { kind: "text", text: "before " },
        { kind: "text", text: "unique pasted match", pasted: true },
        { kind: "text", text },
      ]),
      { rowId: "ordered-paste-find", card: false, needle: "unique pasted match", repaint: () => {} },
    );
    expect(host.querySelector(".cv-user__text")!.classList.contains("is-clamped")).toBe(false);
    expect(host.querySelector(".cv-user__typed")?.textContent).toContain("before unique pasted match");
  });
  for (const attachmentView of ["inline", "strip"] as const) {
    test(`${attachmentView}: a placed sent file and image keep their source's badge`, async () => {
      clearImageEntries();
      resetTranscriptDisclosure();
      resetSourceIcons();
      const asked: string[] = [];
      (dom.window as unknown as Record<string, unknown>).cmuxAcpmuxActions = {
        "attachment.sourceIcon": async (params: Record<string, unknown>) => {
          asked.push(String(params.bundleId));
          return { src: "data:image/png;base64,iVBORw0KGgo=" };
        },
      };
      await act(async () => setComposerSettings({ attachmentView }));
      await render(
        prompt(`sourced-${attachmentView}`, "compare with the numbers", [
          { kind: "text", text: "compare " },
          {
            kind: "image",
            id: `sourced-shot-${attachmentView}`,
            mimeType: "image/png",
            name: "shot.png",
            placed: true,
            source: { name: "Screenshot", bundleId: "com.apple.screenshot.launcher" },
          },
          { kind: "text", text: " with the numbers " },
          {
            kind: "file",
            name: "build-times.csv",
            mimeType: "text/csv",
            size: 18_400,
            uri: "file:///Users/sample/build-times.csv",
            placed: true,
            source: { name: "Finder", bundleId: "com.apple.finder" },
          },
        ]),
      );
      // The host's icon answers land a tick later.
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
      const band = attachmentView === "inline" ? "[data-inline-content]" : "[data-inline-attachment-strip]";
      const file = host.querySelector<HTMLElement>(`${band} .cv-user__inline-file .acpmux-file-chip`)!;
      expect(file).not.toBeNull();
      expect(file.querySelector(".acpmux-source-badge img")?.getAttribute("alt")).toBe("From Finder");
      expect(file.getAttribute("title")).toBe("/Users/sample/build-times.csv\nFrom Finder");
      const image = host.querySelector<HTMLElement>(`${band} .cv-user__inline-image .cv-user__sourced`)!;
      expect(image).not.toBeNull();
      expect(image.querySelector(".acpmux-source-badge img")?.getAttribute("alt")).toBe("From Screenshot");
      expect(asked.sort()).toEqual(["com.apple.finder", "com.apple.screenshot.launcher"]);
      await act(async () => setComposerSettings({ attachmentView: "inline" }));
    });
  }
  // The row's estimate (model.ts inlinePromptHeight) flows a placed prompt's attachments as this CSS
  // lays them out: inline blocks on the text's `pre-wrap` line, each with the margins the estimate
  // adds, an image at the size UserBubble.tsx gives it, and a file at the shared chip's box.
  test("inline: attachments flow on the text's line with the margins the row's estimate adds", async () => {
    clearImageEntries();
    resetTranscriptDisclosure();
    await act(async () => setComposerSettings({ attachmentView: "inline" }));
    await render(
      prompt("estimate-css", "look at this", [
        { kind: "text", text: "look " },
        { kind: "image", id: "wide", mimeType: "image/png", name: "wide.png", width: 1600, height: 400, placed: true },
        { kind: "text", text: " at " },
        { kind: "file", name: "a.csv", uri: "file:///tmp/a.csv", size: 12, placed: true },
      ]),
    );
    const { INLINE_ATTACHMENT_MARGIN, INLINE_FILE_CHIP } = await import("../src/agent-session/acpmux/model");
    const style = (selector: string) => dom.window.getComputedStyle(host.querySelector(selector)!);
    expect(style("[data-inline-content]").whiteSpace).toBe("pre-wrap");
    for (const selector of [
      "[data-inline-content] .cv-user__inline-image",
      "[data-inline-content] .cv-user__inline-file",
    ]) {
      const box = style(selector);
      expect(box.display).toBe("inline-block");
      expect(box.verticalAlign).toBe("middle");
      expect([box.marginTop, box.marginBottom, box.marginLeft, box.marginRight]).toEqual(
        [
          INLINE_ATTACHMENT_MARGIN.y,
          INLINE_ATTACHMENT_MARGIN.y,
          INLINE_ATTACHMENT_MARGIN.x,
          INLINE_ATTACHMENT_MARGIN.x,
        ].map((px) => `${px}px`),
      );
    }
    expect(style("[data-inline-content] .cv-user__inline-file").maxWidth).toBe(
      `min(${INLINE_FILE_CHIP.maxWidth}px, 72vw)`,
    );
    // The image's box: its own shape at most 320 wide and 120 tall (UserBubble.tsx sentImageSize).
    const img = host.querySelector<HTMLImageElement>("[data-inline-content] img")!;
    expect(img.style.width).toBe("320px");
    expect(img.style.aspectRatio.replace(/\s/g, "")).toBe("320/80");
    // The chip's own box (composerAttachments.css `.acpmux-file-chip`): its height, sides and gap.
    const chip = readFileSync(
      new URL("../src/agent-session/acpmux/composerAttachments.css", import.meta.url),
      "utf8",
    ).match(/\n\.acpmux-file-chip \{([^}]*)\}/)![1]!;
    expect(chip).toContain(`--acpmux-file-chip-gap: ${INLINE_FILE_CHIP.gap}px;`);
    expect(chip).toContain(`height: ${INLINE_FILE_CHIP.height}px;`);
    expect(chip).toContain(`padding: 0 ${INLINE_FILE_CHIP.side}px;`);
    expect(chip).toContain(`max-width: min(${INLINE_FILE_CHIP.maxWidth}px, 72vw);`);
  });
} finally {
  afterAll(async () => {
    act(() => root.unmount());
    await settleReact();
    for (const [key, present, value] of saved) {
      if (present) scope[key] = value;
      else delete scope[key];
    }
    dom.window.close();
  });
}
