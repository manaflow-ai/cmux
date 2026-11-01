// l10n-allow-file: gallery fixtures (sample chats, drafts and code), not shipped UI.
// The agent pane at the narrow widths a split leaves it (Leo 2026-10-14, "squashed composers"):
// 280, 360 and 480 px, also at interface scale 0.8 and 1.25. Each play checks the rendered
// geometry: nothing scrolls the page sideways, the composer's controls sit side by side inside
// their row, Send, Stop, Steer and the mic keep their full size, and text that does not fit ends
// in an ellipsis instead of being cut. test/narrow-layouts.test.ts drives every variant at each width.
import { agentPaneEntry } from "../../gallery/format";
import type { Play, PlayContext } from "../../gallery/play";
import { activity, assistant, chat, CWD, noChat, session, summary, tool, user } from "../../gallery/fixtures/acpmux";
import { setComposerSettings } from "./composerSettings";

const controls = {
  model: "claude-opus-5-5",
  effort: "high",
  configOptions: [
    {
      id: "thought_level",
      name: "Speed",
      category: "thought_level",
      currentValue: "medium-fast",
      options: [
        { value: "slow", name: "Slow" },
        { value: "medium-fast", name: "Medium Fast" },
        { value: "fast", name: "Fast" },
      ],
    },
    // Fast mode on: a checkbox row of the model button's menu (Leo 2026-10-20); the row draws no bolt.
    {
      id: "fast-mode",
      name: "Fast mode",
      category: "model_config",
      currentValue: "on",
      options: [
        { value: "off", name: "Off" },
        { value: "on", name: "On" },
      ],
    },
  ],
  modes: {
    currentModeId: "bypassPermissions",
    availableModes: [
      { id: "ask", name: "Ask before edits", description: "Review changes before they run" },
      { id: "bypassPermissions", name: "Bypass permissions", description: "Run actions without approval" },
    ],
  },
};
const withControls = (snapshot: ReturnType<typeof chat>) => ({
  ...snapshot,
  summary: { ...snapshot.summary!, ...controls },
});

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];
const working = [user("Add retries", 1), assistant("Reading the helper…", 0.5, { streaming: true })];

const create = (title: string, number: number) =>
  tool(`gh pr create --title "${title}"`, "execute", "completed", {
    command: `gh pr create --title "${title}" --fill`,
    output: `https://github.com/acme/atlas-web/pull/${number}\n`,
    exitCode: 0,
  });

const code = [
  "```ts",
  "export async function fetchWithRetry(input: RequestInfo, init: RequestInit = {}, policy = defaultRetryPolicy): Promise<Response> {",
  "  for (let attempt = 0; ; attempt++) {",
  "    const response = await fetch(input, init);",
  "    if (!policy.retries(response, attempt)) return response;",
  "  }",
  "}",
  "```",
].join("\n");

const visible = (element: Element) => {
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== "hidden";
};

// An open menu renders inside its chip; the stage judges popups itself (play.ts judgePopups).
const inPopup = (element: Element) => Boolean(element.closest(".ui-popup, .acpmux-mp, [role='menu'], [role='dialog']"));

/** The geometry problems of the pane as rendered; empty when it holds at this width. */
export function narrowProblems(document: Document): string[] {
  const view = document.defaultView!;
  const problems: string[] = [];
  const page = document.scrollingElement ?? document.documentElement;
  if (page.scrollWidth > view.innerWidth + 1)
    problems.push(`the page scrolls sideways (${page.scrollWidth} > ${view.innerWidth})`);
  const rows: [string, string][] = [
    [".acpmux-composer-bar", "composer bar"],
    [".nt-pickers", "New Tab chips"],
    [".acpmux-composer-context", "location row"],
  ];
  for (const [selector, name] of rows)
    for (const row of document.querySelectorAll(selector)) {
      if (!visible(row)) continue;
      const box = row.getBoundingClientRect();
      // The innermost controls: a chip's wrapper and its button are one control.
      const controls = [...row.querySelectorAll("button, a[href], [role='button']")].filter(
        (control) =>
          visible(control) && !control.querySelector("button, a[href], [role='button']") && !inPopup(control),
      );
      const rects = controls.map((control) => ({ control, rect: control.getBoundingClientRect() }));
      for (const { control, rect } of rects)
        if (rect.left < box.left - 1 || rect.right > box.right + 1)
          problems.push(
            `${name}: ${label(control)} leaves the row (${Math.round(rect.left)}–${Math.round(rect.right)} of ${Math.round(box.left)}–${Math.round(box.right)})`,
          );
      for (let i = 0; i < rects.length; i++)
        for (let j = i + 1; j < rects.length; j++) {
          const a = rects[i]!.rect;
          const b = rects[j]!.rect;
          const width = Math.min(a.right, b.right) - Math.max(a.left, b.left);
          const height = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
          if (width > 1 && height > 1)
            problems.push(`${name}: ${label(rects[i]!.control)} overlaps ${label(rects[j]!.control)}`);
        }
      // An icon drawn narrower than its own size is a squeezed control (a model chip read as "•").
      for (const icon of row.querySelectorAll<SVGSVGElement>("svg[viewBox]")) {
        const { width, height } = icon.getBoundingClientRect();
        const box = icon.viewBox.baseVal;
        if (!width || !height || !box?.height) continue;
        const drawn = height * (box.width / box.height);
        if (width + 1 < drawn)
          problems.push(
            `${name}: an icon of ${label(icon.closest("button") ?? icon)} is squeezed to ${width.toFixed(1)}px of ${drawn.toFixed(1)}px`,
          );
      }
      for (const text of row.querySelectorAll("span, button, a")) {
        if (!visible(text) || !text.textContent?.trim() || text.children.length || inPopup(text)) continue;
        const style = getComputedStyle(text);
        if (
          text.scrollWidth > text.clientWidth + 1 &&
          style.overflowX !== "visible" &&
          style.textOverflow !== "ellipsis"
        )
          problems.push(`${name}: “${text.textContent.trim()}” is cut off`);
      }
    }
  // The effort is the model button's detail ("Opus 5.5  Medium", Leo 2026-10-20): it may shrink to
  // its short name, never go.
  for (const button of document.querySelectorAll(".acpmux-model .acpmux-picker-button")) {
    const details = [...button.querySelectorAll(".acpmux-model-detail")];
    if (details.length && !details.some(visible)) problems.push("the model button's effort is hidden");
  }
  // A wide pane collapses nothing: the model and its effort show in full (a size container that
  // measured a wide composer as narrow would hide them, Lawrence 2026-10-14 "lost effort"). At 600 px
  // the controls still share the row, so the model name and effort may end in an ellipsis there.
  if (view.innerWidth >= 700)
    // The row's wide forms (composerRowFit.ts): effort's level, and the model's name or its drawn
    // name without the vendor ("Opus 5.5"); the narrow forms are laid out of the row.
    for (const value of document.querySelectorAll(
      ".acpmux-model-detail:not(.acpmux-fit-label), .acpmux-model-name:not([data-short]), .acpmux-model .acpmux-fit-label[data-fit-forms~='full']",
    ))
      if (!visible(value) || value.scrollWidth > value.clientWidth + 1)
        problems.push(`“${value.textContent?.trim()}” is not shown in full in a wide pane`);
  // The model goes to its mark alone only where the row cannot hold its name beside the other
  // controls (composerRowFit.ts modelMark, a composer under 370 px): wider, a name shows whole, in
  // full, without its vendor ("Opus 5.5") or as its family ("Opus").
  if (view.innerWidth >= 420)
    for (const button of document.querySelectorAll(".acpmux-model .acpmux-picker-button")) {
      const named = [button, ...button.querySelectorAll("*")].some(
        (part) =>
          visible(part) &&
          ([...part.childNodes].some((node) => node.nodeType === 3 && node.textContent?.trim()) ||
            /^".+"$/.test(getComputedStyle(part, "::before").content)),
      );
      if (!named) problems.push("the model is cut to its icon in a pane with room for its name");
    }
  // Fast mode is a row of the model button's menu, never a bolt in the composer (Leo 2026-10-20).
  if (document.querySelector(".acpmux-fast")) problems.push("the composer draws a speed bolt");
  // The chips and the turn's controls share one line: Send never wraps under the pickers.
  for (const row of document.querySelectorAll(".acpmux-composer-bar, .nt-pickers")) {
    const chip = row.querySelector(".acpmux-chips > *");
    const send = row.querySelector(".acpmux-send, .acpmux-cancel");
    if (!chip || !send || !visible(chip) || !visible(send)) continue;
    const middle = (element: Element) => {
      const rect = element.getBoundingClientRect();
      return rect.top + rect.height / 2;
    };
    if (Math.abs(middle(chip) - middle(send)) > 4)
      problems.push(`${row.className.toString().split(" ")[0]}: Send wraps below the chips`);
  }
  // The turn's own controls never shrink: a squeezed Send is the first thing a narrow pane breaks.
  for (const selector of [".acpmux-send", ".acpmux-cancel", ".acpmux-mic"])
    for (const control of document.querySelectorAll(selector)) {
      if (!visible(control)) continue;
      const rect = control.getBoundingClientRect();
      if (rect.width < Math.min(24, rect.height) || rect.width < rect.height - 1)
        problems.push(`${selector} is squeezed to ${rect.width.toFixed(1)}×${rect.height.toFixed(1)}`);
    }
  // A code block scrolls inside itself, never wider than the transcript.
  for (const block of document.querySelectorAll(".cv-codeblock, .cv-code")) {
    const scroller = block.closest(".acpmux-scroll");
    if (!scroller || !visible(block)) continue;
    if (block.getBoundingClientRect().right > scroller.getBoundingClientRect().right + 1)
      problems.push("a code block is wider than the transcript");
  }
  return problems;
}

function label(control: Element) {
  return control.getAttribute("aria-label") || control.textContent?.trim() || control.className.toString();
}

const check: Play = async (ctx: PlayContext) => {
  // The pointer resting on the prompt is the step the report records; the geometry is the check.
  await ctx.hover({ selector: ".acpmux-composer-box, .nt-screen, .acpmux-newtab" });
  const problems = narrowProblems(ctx.document);
  if (problems.length) throw new Error(problems.join("; "));
};

/// The model button's open menus (the compact one, its submenus, the full picker) inside the chat
/// column: a chip near the column's edge never opens a menu past it, over the rail beside it or off
/// the pane (the context-menus lane, 2026-10-20: "the model menu overflows the column").
function menusLeaveColumn(document: Document): string[] {
  const view = document.defaultView!;
  const box = document.querySelector(".acpmux-main")?.getBoundingClientRect() ?? { left: 0, right: view.innerWidth };
  const problems: string[] = [];
  for (const menu of document.querySelectorAll(".acpmux-quick-menu, .acpmux-mp")) {
    const rect = menu.getBoundingClientRect();
    if (rect.width === 0) continue;
    if (rect.left < box.left - 1 || rect.right > box.right + 1)
      problems.push(
        `the model menu leaves the chat column (${Math.round(rect.left)}–${Math.round(rect.right)} of ${Math.round(box.left)}–${Math.round(box.right)})`,
      );
  }
  return problems;
}

/// Opens the model button's menu and checks that it keeps to the chat column.
async function openModelMenu(ctx: PlayContext) {
  const btns = [...ctx.document.querySelectorAll<HTMLElement>("button")].filter((b) => (b.getAttribute("aria-label") ?? b.textContent ?? "").includes("Model")).map((b) => { const x = b.getBoundingClientRect(); const h = ctx.document.elementFromPoint(x.left + x.width / 2, x.top + x.height / 2); return `${b.className}[${b.getAttribute("aria-label")}] ${Math.round(x.left)},${Math.round(x.top)} ${Math.round(x.width)}x${Math.round(x.height)} hit=${h?.tagName}.${h?.className}`; }).join(" ; ");
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu")).catch(() => {
    throw new Error(`DIAG GEO ${(ctx.document.defaultView as unknown as { __geo?: string }).__geo} DIAG model menu did not open; column ${Math.round(ctx.document.querySelector(".acpmux-main")?.getBoundingClientRect().width ?? 0)}; buttons ${btns}; popups ${[...ctx.document.querySelectorAll("[role=menu],[role=dialog],[role=listbox]")].map((e) => e.className).join(",")}`);
  });
  // Base UI places and sizes the menu over a frame or two (its --available-width): wait for it to
  // rest inside the column rather than read its first frame.
  await ctx.waitFor(() => menusLeaveColumn(ctx.document).length === 0, { capMs: 1000 }).catch(() => undefined);
  const problems = menusLeaveColumn(ctx.document);
  if (problems.length) throw new Error(problems.join("; "));
}

export default agentPaneEntry({
  id: "agent-pane.narrow",
  title: "Narrow panes",
  area: "Agent pane",
  height: 560,
  // The three presets are the widths a split leaves the pane: the stage renders each in the PR diff.
  widths: { narrow: 280, normal: 360, wide: 480 },
  covers: [
    "agent-session/acpmux/Composer.tsx#Composer",
    "agent-session/acpmux/ComposerPickers.tsx#ComposerPickers",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
  ],
  variants: {
    controls: {
      note: "A finished chat with every composer control: model, effort, access, Fast mode in the picker, mic and Send.",
      snapshot: withControls(chat(finished)),
      play: check,
    },
    permission: {
      note: "A chat allowed to act without asking: the grant shows on the mode's lock; no other chip joins the bar.",
      snapshot: {
        ...withControls(chat(finished)),
        permissionGroups: {
          supported: true,
          ready: true,
          busy: false,
          loading: false,
          chatAllowance: true,
          groups: [],
        },
      },
      play: check,
    },
    "model-menu": {
      note: "Play: open the model button's menu (icon-only below 330px); it stays inside the pane, unclipped, and inside a chat column narrower than the pane (200 px), its width giving way.",
      checks: {
        popupLayer: { value: true, reason: "A chip's menu renders inside the chip row; a clipping row hides it." },
        layoutShiftMax: {
          value: 0.001,
          reason:
            "Reopening the portaled picker after narrowing the chat has a 0.0004 base shift from composer controls.",
        },
      },
      snapshot: withControls(chat(finished)),
      play: async (ctx) => {
        await openModelMenu(ctx);
        await check(ctx);
        // Then a chat column narrower than the pane, as a docked rail beside it leaves it: 200 px at
        // the pane's left, under the menu's 220 px floor and 300 px width. The menu gives way and
        // keeps to the column, never past its edge.
        await ctx.press("Escape");
        // Closed means gone, or still mounted but marked closed or hidden; an open popup has
        // neither, so this never passes while the menu is still up.
        await ctx.waitFor(() => {
          const menu = ctx.document.querySelector<HTMLElement>(".acpmux-quick-menu");
          return (
            !menu ||
            menu.hasAttribute("data-closed") ||
            ctx.document.defaultView?.getComputedStyle(menu).visibility === "hidden"
          );
        }).catch(() => {
          const menu = ctx.document.querySelector<HTMLElement>(".acpmux-quick-menu");
          throw new Error(`DIAG Escape did not close: ${menu?.className} ${[...(menu?.attributes ?? [])].map((a) => `${a.name}=${a.value}`).join(",")} active=${ctx.document.activeElement?.tagName}.${ctx.document.activeElement?.className}`);
        });
        const column = ctx.document.querySelector<HTMLElement>(".acpmux-main");
        if (!column) throw new Error("no chat column");
        const geo: string[] = [];
        for (const w of [480, 420, 380, 360, 340, 320, 300, 280, 260, 240, 220, 200]) {
          column.style.flex = `0 0 ${w}px`;
          await new Promise((resolve) => ctx.document.defaultView!.requestAnimationFrame(() => ctx.document.defaultView!.requestAnimationFrame(resolve)));
          const dots = ctx.document.querySelector(".acpmux-look-dots .nt-style-options")?.getBoundingClientRect();
          const foot = ctx.document.querySelector(".acpmux-composer-foot");
          const kids = [...(foot?.querySelectorAll<HTMLElement>("button, [role=button]") ?? [])].map((b) => { const r = b.getBoundingClientRect(); return `${(b.getAttribute("aria-label") ?? "").slice(0, 8)}:${Math.round(r.left)}-${Math.round(r.right)}`; }).join(" ");
          geo.push(`w${w} col ${Math.round(column.getBoundingClientRect().width)} dots ${Math.round(dots?.left ?? -1)}-${Math.round(dots?.right ?? -1)} foot ${kids}`);
        }
        (ctx.document.defaultView as unknown as { __geo: string }).__geo = geo.join(" || ");
        column.style.flex = "0 0 200px";
        await ctx.waitFor(() => column.getBoundingClientRect().width <= 201).catch(() => {
          throw new Error(`DIAG column stayed ${column.getBoundingClientRect().width}`);
        });
        // The narrowing is the stage's, not a step's: let it paint before the next step measures shifts.
        const view = ctx.document.defaultView!;
        await new Promise((resolve) => view.requestAnimationFrame(() => view.requestAnimationFrame(resolve)));
        await new Promise((resolve) => view.setTimeout(resolve, 0));
        await openModelMenu(ctx);
      },
    },
    "access-menu": {
      note: "Play: open the access menu from its chip, down to its lock in a short row.",
      checks: {
        popupLayer: { value: true, reason: "A chip's menu renders inside the chip row; a clipping row hides it." },
      },
      snapshot: withControls(chat(finished)),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Mode" });
        await ctx.waitFor(() => ctx.document.querySelector("[role='menu']"));
        await check(ctx);
      },
    },
    summary: {
      note: "Play: open the chat summary; the card fits the pane.",
      snapshot: withControls(chat(finished)),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-summary-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-card"));
        const card = ctx.document.querySelector(".acpmux-summary-card")!.getBoundingClientRect();
        const view = ctx.document.defaultView!;
        if (card.left < -1 || card.right > view.innerWidth + 1) throw new Error("the summary card leaves the pane");
        await check(ctx);
      },
    },
    working: {
      note: "A turn running: Stop beside the mic.",
      snapshot: withControls(chat(working, { isWorking: true })),
      play: check,
    },
    "pull-requests": {
      note: "Two pull request bars over the composer, with long titles.",
      snapshot: withControls(
        chat([
          user("Split the change into two PRs", 6),
          activity(
            [
              create("Add retry with exponential backoff to the uploader and the fetch helper", 128),
              create("Cover retry with a test", 129),
            ],
            5,
          ),
          assistant("Both PRs are open.", 2),
          summary(2, { status: "completed", durationMs: 74_000, toolCount: 2 }),
        ]),
      ),
      play: check,
    },
    "new-tab": {
      note: "The New Tab page with its composer and recent chats.",
      ready: {
        newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", template: "cards" },
        newSession: true,
      },
      snapshot: noChat([session({ sessionId: "older", title: "Add retry with exponential backoff to the uploader" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", ...controls },
      }),
      play: check,
    },
    // CI plays these in Linux Chromium, whose fallback fonts set the chips' labels wider than macOS
    // does: the New Tab row at 280 px passed on a Mac with half a pixel of overlap and failed in CI
    // ("Mode overlaps Dictate"). Spacing the page's letters out by half a pixel stands in for those
    // metrics, so a row with no slack fails on a Mac too.
    "new-tab-wide-type": {
      note: "The New Tab page with its letters spaced half a pixel wider, as Linux's fonts set them.",
      ready: {
        newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", template: "cards" },
        newSession: true,
      },
      snapshot: noChat([session({ sessionId: "older", title: "Add retry with exponential backoff to the uploader" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", ...controls },
      }),
      play: async (ctx) => {
        const style = ctx.document.createElement("style");
        style.textContent = ".nt-screen, .nt-screen * { letter-spacing: 0.5px; }";
        ctx.document.head.append(style);
        const view = ctx.document.defaultView!;
        await new Promise((done) => view.requestAnimationFrame(() => view.requestAnimationFrame(done)));
        await check(ctx);
      },
    },
    // Both templates keep the model and mode in the shared footer; this variant checks the
    // Default template with Linux's wider type, and the next checks a chat with plain styling off.
    "new-tab-default": {
      note: "New Tab's Default template: model and mode in the shared footer, mic and Send in the box, with Linux's wider letter spacing.",
      ready: {
        newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", template: "default" },
        newSession: true,
      },
      snapshot: noChat([session({ sessionId: "older", title: "Add retry with exponential backoff to the uploader" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", ...controls },
      }),
      play: async (ctx) => {
        if (
          !ctx.document.querySelector(".nt-foot .acpmux-model") ||
          ctx.document.querySelector(".nt-box .nt-pickers .acpmux-model")
        )
          throw new Error("the Default template's model is not in the shared footer");
        const style = ctx.document.createElement("style");
        style.textContent = ".nt-screen, .nt-screen * { letter-spacing: 0.5px; }";
        ctx.document.head.append(style);
        const view = ctx.document.defaultView!;
        await new Promise((done) => view.requestAnimationFrame(() => view.requestAnimationFrame(done)));
        await check(ctx);
      },
    },
    "controls-single-row": {
      note: "The chat composer with plain footer styling off: the model and mode keep the shared footer, while mic and Send stay in the box.",
      snapshot: withControls(chat(finished)),
      play: async (ctx) => {
        // The legacy variant id stays stable, but both looks now anchor model and mode in the footer.
        setComposerSettings({ plainFooter: false });
        await ctx.waitFor(() => {
          const footer = ctx.document.querySelector(".acpmux-composer-foot");
          return (
            footer?.getAttribute("data-footer-look") === null &&
            footer.querySelector(".acpmux-model") !== null &&
            ctx.document.querySelector(".acpmux-composer-box .acpmux-model") === null
          );
        });
        // Toggling the plain style is a layout change: settle before measuring the control rows.
        const view = ctx.document.defaultView!;
        await new Promise((done) => view.setTimeout(done, 600));
        await new Promise((done) => view.requestAnimationFrame(() => view.requestAnimationFrame(done)));
        await check(ctx);
      },
    },
    code: {
      note: "A reply with a long code line and a long path: the block scrolls inside itself.",
      snapshot: withControls(
        chat([
          user("Show me the helper", 4),
          assistant(`Here it is, in \`${CWD}/src/network/fetchWithRetry.ts\`:\n\n${code}`, 3),
          summary(3, { status: "completed" }),
        ]),
      ),
      play: check,
    },
  },
});
