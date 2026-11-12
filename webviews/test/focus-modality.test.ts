// FOCUS-RING (src/ui/focusModality.ts). Leo, 2026-11-06: "i need the focus ring to STOP FIRING SO
// OFTEN AND TO BE ABLE TO CANCEL IT JUST GETS STUCK IN THESE SITUATIONS". The ring shows only for
// focus a navigation key moved; a click, Escape, a scroll or a pointer move takes it away; it can
// never outlive what set it.
//
// Three parts:
// - the owner's state machine, in happy-dom;
// - the build gate: every `:focus-visible` a stylesheet writes is gated (postcss.config.mjs);
// - the detectors that keep it so: no stylesheet draws a ring from a bare `:focus` or
//   `:focus-within` (which the gate cannot see), and no code asks `matches(":focus-visible")`
//   instead of focusRingShown.
// test/focus-modality-browser.test.ts drives the same rule in real Chromium and WebKit.
import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Window } from "happy-dom";
import postcss from "postcss";
import focusRingGate, { FOCUS_RING_GATE as BUILD_GATE, gateFocusVisible } from "../scripts/postcss/focusRingGate.mjs";
import {
  EARN_WINDOW_MS,
  FOCUS_MODALITY_ATTRIBUTE,
  FOCUS_RING_GATE,
  dismissFocusRing,
  earnFocusRing,
  focusCameFromKey,
  focusModality,
  installFocusModality,
} from "../src/ui/focusModality";

const webviews = path.resolve(import.meta.dir, "..");

function page() {
  const window = new Window();
  const doc = window.document as unknown as Document;
  // The owner reads the page's clock; the test moves it instead of sleeping.
  const clock = { now: 0 };
  Object.defineProperty(window.performance, "now", { value: () => clock.now });
  doc.body.innerHTML = `<button id="a">A</button><button id="b">B</button><input id="field">`;
  const stop = installFocusModality(doc);
  const view = window as unknown as Window & typeof globalThis;
  const el = (id: string) => doc.getElementById(id) as HTMLElement;
  const key = (key: string, init: KeyboardEventInit = {}) =>
    view.dispatchEvent(new view.KeyboardEvent("keydown", { key, bubbles: true, ...init }));
  const pointer = (type: string, x = 0, y = 0) =>
    view.dispatchEvent(new view.PointerEvent(type, { clientX: x, clientY: y, bubbles: true }));
  /** A Tab press that moves focus, as the browser does it: the key, then focus lands. */
  const tabTo = (id: string) => {
    (doc.activeElement as HTMLElement | null)?.blur();
    key("Tab");
    el(id).focus();
  };
  return { window, doc, view, el, key, pointer, tabTo, stop, clock, mode: () => focusModality(doc) };
}

describe("the focus-ring owner", () => {
  test("starts with rings off", () => {
    const p = page();
    expect(p.doc.documentElement.getAttribute(FOCUS_MODALITY_ATTRIBUTE)).toBe("pointer");
  });

  test("only a navigation key that moves focus earns the ring", () => {
    const p = page();
    p.el("a").focus(); // code, or a click
    expect(p.mode()).toBe("pointer");
    p.tabTo("b");
    expect(p.mode()).toBe("keyboard");
    for (const k of ["ArrowDown", "ArrowRight", "Home", "End", "PageDown"]) {
      p.el("a").blur();
      p.key(k);
      p.el("a").focus();
      expect(p.mode()).toBe("keyboard");
    }
  });

  test("a shortcut that moves focus earns none (Cmd-K, Cmd-L, a pane switch)", () => {
    const p = page();
    p.key("k", { metaKey: true });
    p.el("field").focus();
    expect(p.mode()).toBe("pointer");
    p.key("ArrowLeft", { metaKey: true, altKey: true });
    p.el("a").focus();
    expect(p.mode()).toBe("pointer");
    p.key("Enter");
    p.el("b").focus();
    expect(p.mode()).toBe("pointer");
  });

  test("a focus move long after the key earns none, even while the ring was on", () => {
    const p = page();
    p.tabTo("a");
    expect(p.mode()).toBe("keyboard");
    p.clock.now += EARN_WINDOW_MS + 1;
    p.el("b").focus(); // code moving focus later (a dialog opening, a reply landing)
    expect(p.mode()).toBe("pointer");
  });

  test("another key (Enter, Space, a letter) takes it away; a modifier alone does not", () => {
    const p = page();
    for (const k of ["Enter", " ", "a"]) {
      p.tabTo("a");
      p.key("Shift");
      expect(p.mode()).toBe("keyboard");
      p.key(k);
      expect([k, p.mode()]).toEqual([k, "pointer"]);
    }
  });

  test("a focus move right after a clear, still inside the key's window, earns nothing back", () => {
    const p = page();
    for (const clear of [() => p.pointer("pointerdown"), () => p.key("Escape"), () => p.key("Enter")]) {
      p.tabTo("a");
      clear();
      p.el("b").focus(); // a click's focus, or an Escape or Enter handler's, within EARN_WINDOW_MS
      expect(p.mode()).toBe("pointer");
    }
  });

  test("a command the app's key router ran forgets the key: its focus earns none, even right after a Tab", () => {
    const p = page();
    p.tabTo("a");
    dismissFocusRing(p.doc); // pageStreams' onCommand and the pane's command() do this first
    p.el("field").focus(); // Cmd-F's focusSearch
    expect(p.mode()).toBe("pointer");
  });

  test("the key is spent two frames after it: a code focus then earns none, inside the time window too", async () => {
    const p = page();
    p.tabTo("a");
    const frame = () => new Promise((resolve) => p.view.requestAnimationFrame(resolve));
    await frame();
    await frame();
    await frame();
    p.el("b").focus(); // the clock has not moved: only the frames ended the key
    expect(p.mode()).toBe("pointer");
  });

  test("a focus guard's hand-off within the key's window keeps the ring", () => {
    const p = page();
    p.tabTo("a");
    p.el("b").focus(); // a guard or handler moving the same key's focus on
    expect(p.mode()).toBe("keyboard");
  });

  test("a press, Escape, a scroll or leaving the window takes it away, and focus stays", () => {
    const p = page();
    const clears: [string, () => void][] = [
      ["pointerdown", () => p.pointer("pointerdown")],
      ["Escape", () => p.key("Escape")],
      ["wheel", () => p.view.dispatchEvent(new p.window.WheelEvent("wheel", { deltaY: 4 }) as unknown as Event)],
      ["blur", () => p.view.dispatchEvent(new p.window.Event("blur") as unknown as Event)],
    ];
    for (const [name, clear] of clears) {
      p.tabTo("a");
      expect(p.mode()).toBe("keyboard");
      clear();
      expect([name, p.mode()]).toEqual([name, "pointer"]);
      expect(p.doc.activeElement).toBe(p.el("a"));
    }
  });

  test("one long pointer move takes it away, measured from where it started", () => {
    const p = page();
    p.tabTo("a");
    p.view.dispatchEvent(
      new p.view.PointerEvent("pointermove", {
        clientX: 130,
        clientY: 100,
        movementX: 30,
        bubbles: true,
      } as PointerEventInit),
    );
    expect(p.mode()).toBe("pointer");
  });

  test("a pointer move past a few pixels takes it away; a resting hand's jitter does not", () => {
    const p = page();
    p.tabTo("a");
    p.pointer("pointermove", 100, 100);
    p.pointer("pointermove", 102, 101);
    expect(p.mode()).toBe("keyboard");
    p.pointer("pointermove", 120, 100);
    expect(p.mode()).toBe("pointer");
    // The next earned ring measures from where the pointer is then, not from the old anchor.
    p.tabTo("b");
    p.pointer("pointermove", 121, 100);
    expect(p.mode()).toBe("keyboard");
  });

  test("a gallery's staged focus earns the ring as a key would, and the pointer still takes it", () => {
    const p = page();
    p.el("field").focus();
    earnFocusRing(p.doc);
    expect(p.mode()).toBe("keyboard");
    p.pointer("pointermove", 0, 0);
    p.pointer("pointermove", 40, 0);
    expect(p.mode()).toBe("pointer");
  });

  test("a ring moved by key measures pointer slop afresh from its new place", () => {
    const p = page();
    p.tabTo("a");
    p.pointer("pointermove", 100, 100);
    p.pointer("pointermove", 104, 100); // 4 px on the first ring
    p.tabTo("b");
    p.pointer("pointermove", 107, 100); // 3 px on the new one
    expect(p.mode()).toBe("keyboard");
  });

  test("focus a key gave stays the key's after a pointer move takes the ring away", () => {
    const p = page();
    p.tabTo("a");
    p.pointer("pointermove", 0, 0);
    p.pointer("pointermove", 40, 0);
    expect(p.mode()).toBe("pointer");
    expect(focusCameFromKey(p.el("a"))).toBe(true); // the minimap keeps the keyboard on its tick
    p.el("b").focus(); // code or a click
    expect(focusCameFromKey(p.el("b"))).toBe(false);
    expect(focusCameFromKey(p.el("a"))).toBe(false);
  });

  test("a stop leaves the page with no attribute (rings as before)", () => {
    const p = page();
    p.stop();
    expect(p.doc.documentElement.hasAttribute(FOCUS_MODALITY_ATTRIBUTE)).toBe(false);
  });
});

describe("the build gate", () => {
  test("the build and the runtime share one gate, and it adds no specificity", () => {
    expect(BUILD_GATE).toBe(FOCUS_RING_GATE);
    // A gated rule weighs what it did (the shell composer's rim still outranks the focus rim).
    expect(FOCUS_RING_GATE).toMatch(/^:where\(.*\)$/);
  });

  test("every :focus-visible is gated, inside :not() and :has() too, once", () => {
    expect(gateFocusVisible(".b:focus-visible")).toBe(`.b:focus-visible${FOCUS_RING_GATE}`);
    expect(gateFocusVisible(":focus:not(:focus-visible)")).toBe(`:focus:not(:focus-visible${FOCUS_RING_GATE})`);
    // After the :has(), not inside it: WebKit does not restyle a :has() that holds the gate.
    expect(gateFocusVisible(".box:has(:focus-visible) .x")).toBe(`.box:has(:focus-visible)${FOCUS_RING_GATE} .x`);
    expect(gateFocusVisible(".o:has(:focus-visible)::before")).toBe(`.o:has(:focus-visible)${FOCUS_RING_GATE}::before`);
    expect(gateFocusVisible(".a:is(:focus-visible, :has(:focus-visible)), .c:focus-visible > .d")).toBe(
      `.a:is(:focus-visible${FOCUS_RING_GATE}, :has(:focus-visible)${FOCUS_RING_GATE}), .c:focus-visible${FOCUS_RING_GATE} > .d`,
    );
    // An alternative that is not focus keeps its own meaning (hover still lights the button).
    expect(gateFocusVisible(".p:is(:hover, :focus-visible)")).toBe(`.p:is(:hover, :focus-visible${FOCUS_RING_GATE})`);
    expect(gateFocusVisible(".r:not(:has(:focus-visible))")).toBe(`.r:not(:has(:focus-visible${FOCUS_RING_GATE}))`);
    // A grip's hover shares the :has() with its focus (sessionInfo.css): hover still hides the count
    // with the ring off, so the selector is listed once ungated with the focus branch never matching.
    expect(gateFocusVisible(".s:is(:has(> .h:is(:hover, :focus-visible)), [data-dragging]) .c")).toBe(
      `.s:is(:has(> .h:is(:hover, :not(*))), [data-dragging]) .c, .s:is(:has(> .h:is(:hover, :focus-visible))${FOCUS_RING_GATE}, [data-dragging]) .c`,
    );
    expect(gateFocusVisible('.x[data-a=")"]:has(:focus-visible)')).toBe(
      `.x[data-a=")"]:has(:focus-visible)${FOCUS_RING_GATE}`,
    );
    const once = gateFocusVisible(".b:focus-visible");
    expect(gateFocusVisible(once)).toBe(once);
    expect(gateFocusVisible(".b:focus-within")).toBe(".b:focus-within");
  });

  test("a rule that only shows a control stays on real focus; a mixed rule gates only its ring", async () => {
    const run = async (css: string) =>
      (await postcss([focusRingGate()]).process(css, { from: undefined })).css.replace(/\}\s+/g, "}");
    // Messages' draft close (display) and the model picker's star (Tailwind focus-visible:visible):
    // taking the ring away must not hide the focused control.
    const draft = ".hm-row.draft:hover .hm-draft-close,\n.hm-draft-close:focus-visible{display:inline-flex}";
    expect(await run(draft)).toBe(draft);
    expect(await run(".focus-visible\\:visible:focus-visible{visibility:visible}")).toBe(
      ".focus-visible\\:visible:focus-visible{visibility:visible}",
    );
    // A pseudo-element's opacity is the ring's own drawing (the tray tab's hat), gated whole.
    expect(await run(".t:focus-visible > .h::before{background:red;opacity:1}")).toBe(
      `.t:focus-visible${FOCUS_RING_GATE} > .h::before{background:red;opacity:1}`,
    );
    expect(await run(".y:focus-visible{outline:1px solid;opacity:1}")).toBe(
      `.y:focus-visible{opacity:1}.y:focus-visible${FOCUS_RING_GATE}{outline:1px solid}`,
    );
  });

  test("postcss.config.mjs runs it on every webviews stylesheet", async () => {
    const config = (await import("../postcss.config.mjs")).default as { plugins: { postcssPlugin: string }[] };
    expect(config.plugins.map((p) => p.postcssPlugin)).toContain(focusRingGate().postcssPlugin);
    const out = await postcss(config.plugins as never).process(".x:focus-visible{outline:1px solid}", {
      from: undefined,
    });
    expect(out.css).toBe(`.x:focus-visible${FOCUS_RING_GATE}{outline:1px solid}`);
  });
});

const tracked = (pattern: string) =>
  execFileSync("git", ["ls-files", pattern], { cwd: webviews, encoding: "utf8" })
    .split("\n")
    .filter((f) => f && !/(\.gallery\.|\/gallery\/|\/fixtures\/|\.test\.)/.test(f));
// A git pathspec's `*` crosses directories: `src/*.css` is every stylesheet, `src/styles.css` (the diff
// viewer's) included, which `src/**/*.css` left out.

/** Declarations that draw a ring or a focused edge. */
const DRAWS =
  /^(outline(-color|-width|-style)?|box-shadow|border(-top|-bottom|-left|-right)?(-color)?|--[\w-]*(ring|edge|focus|rim)[\w-]*)$/;

/** Whether `selector` asks for plain focus (`:focus`, `:focus-within`) outside a `:not(...)`. */
function asksPlainFocus(selector: string): boolean {
  let s = selector;
  let previous;
  do {
    previous = s;
    s = s.replace(/:not\((?:[^()]|\([^()]*\))*\)/g, "");
  } while (s !== previous);
  return /:focus(-within)?(?![\w-])/.test(s);
}

describe("detectors", () => {
  test("no stylesheet draws a ring from a bare :focus or :focus-within", () => {
    const offenders: string[] = [];
    for (const file of tracked("src/*.css")) {
      postcss.parse(readFileSync(path.join(webviews, file), "utf8"), { from: file }).walkRules((rule) => {
        const draws = rule.nodes.filter(
          (d) => d.type === "decl" && DRAWS.test(d.prop) && !/^(none|0|transparent)\b/.test(d.value.trim()),
        );
        if (!draws.length) return;
        for (const selector of rule.selectors)
          if (asksPlainFocus(selector)) offenders.push(`${file}:${rule.source?.start?.line} ${selector}`);
      });
    }
    // A click or code focus matches :focus and :focus-within, so such a ring shows for focus
    // nobody keyed and stays until focus leaves. Write :focus-visible (or :has(:focus-visible)),
    // which the build gates.
    expect(offenders).toEqual([]);
  });

  test("code asks focusRingShown, never matches(':focus-visible')", () => {
    const offenders = tracked("src/*.ts*").filter(
      (file) =>
        file !== "src/ui/focusModality.ts" &&
        /matches\(\s*["'`]:focus-visible["'`]\s*\)/.test(readFileSync(path.join(webviews, file), "utf8")),
    );
    expect(offenders).toEqual([]);
  });

  test("every app bundle script runs the gate on the CSS it ships", () => {
    // These build with esbuild or join sheets, so postcss.config.mjs never runs for them.
    const repo = path.resolve(webviews, "..");
    const scripts = execFileSync("git", ["ls-files", "scripts/cmux-next/build-*-web.sh"], {
      cwd: repo,
      encoding: "utf8",
    })
      .split("\n")
      .filter(Boolean);
    const offenders = scripts.filter((file) => {
      const text = readFileSync(path.join(repo, file), "utf8");
      const shipsStyles = /app\.css|styles\.css/.test(text) && /<style>/.test(text);
      const ownsDesktopPage = !/optchat-inspector/.test(file); // the inspector installs no owner
      return shipsStyles && ownsDesktopPage && !text.includes("scripts/postcss/gate-css.mjs");
    });
    expect(scripts.length).toBeGreaterThan(0);
    expect(offenders).toEqual([]);
  });

  test("the gate script gates a sheet in place", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "gate-css-"));
    const file = path.join(dir, "a.css");
    writeFileSync(file, ".b:focus-visible{outline:1px solid}.c:has(:focus-visible){color:red}");
    execFileSync("bun", ["scripts/postcss/gate-css.mjs", file], { cwd: webviews });
    expect(readFileSync(file, "utf8")).toBe(
      `.b:focus-visible${FOCUS_RING_GATE}{outline:1px solid}.c:has(:focus-visible)${FOCUS_RING_GATE}{color:red}`,
    );
    rmSync(dir, { recursive: true });
  });

  test("every page that boots the desktop layer installs the owner", () => {
    const desktop = readFileSync(path.join(webviews, "src/pages/shared/desktop.ts"), "utf8");
    expect(desktop).toMatch(/installFocusModality\(doc\)/);
    // A command the app's key router took never reached the page as a key: it drops the ring first.
    for (const [file, call] of [
      ["src/pages/shared/pageStreams.ts", /\(data\) => \{(?:\s*\/\/.*)*\s*dismissFocusRing\(\);\s*onCommand\(data\);/],
      ["src/agent-session/acpmux/App.tsx", /command\(name, sessionId\) \{(?:\s*\/\/.*)*\s*dismissFocusRing\(\);/],
    ] as const)
      expect([file, call.test(readFileSync(path.join(webviews, file), "utf8"))]).toEqual([file, true]);
    // The pages served to a browser outside the app boot without the desktop layer.
    for (const entry of ["src/agent-session/guest/main.tsx", "src/chief-web/main.tsx"])
      expect([entry, readFileSync(path.join(webviews, entry), "utf8").includes("installFocusModality()")]).toEqual([
        entry,
        true,
      ]);
  });
});
