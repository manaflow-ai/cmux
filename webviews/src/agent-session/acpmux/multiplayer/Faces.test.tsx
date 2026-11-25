// l10n-allow-file: test fixtures (made-up people), not shipped UI.
// The shared chat's faces render from plain fields: the author, the header stack with +N, the
// typing line's words, and nothing at all for a reader alone.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChipHost } from "../chips/host";
import { AnsweredBy, AuthorChip, Face, PresenceStack, TypingLine } from "./Faces";
import { ANA, JORDAN, MEI, SAM } from "./people.fixtures";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(node: ReactNode): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const host = dom.window.document.getElementById("root")!;
  act(() => {
    root = createRoot(host);
    root.render(node);
  });
  return host;
}

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("the author chip shows the face and the name", () => {
  const host = render(<AuthorChip author={ANA} />);
  expect(host.querySelector(".cv-face")?.textContent).toBe("A");
  expect(host.querySelector(".cv-author__name")?.textContent).toBe("Ana Ruiz");
});

test("a link guest's author chip says they are a guest, as their held card does", () => {
  // Their name is the one they typed, a label rather than proof (participants.ts `isGuest`): after
  // Approve their prompt keeps "<name> (guest)" over its bubble.
  const guest = { id: "guest:sh-1.g-1", name: "Sam" };
  const host = render(<AuthorChip author={guest} />);
  expect(host.querySelector(".cv-author__name")?.textContent).toBe("Sam (guest)");
});

test("a prompt's author picture is a person's face at the author face token, not a 14-16px mark", () => {
  // Leo, 2026-11-07: "as if the user sent it, but, like, with their profile avatar picture
  // instead". The face over the bubble takes `--cv-author-face` (multiplayer.css: five grid units,
  // the header's person faces, scaling with the interface), with its initials scaled to it.
  const host = render(
    <AuthorChip author={{ id: "guest:sh-1.g-1", name: "Priya Raman", avatar: "https://a.example/p.png" }} />,
  );
  const face = host.querySelector<HTMLElement>(".cv-author .cv-face")!;
  expect(face.style.width).toBe("var(--cv-author-face)");
  expect(face.style.height).toBe("var(--cv-author-face)");
  expect(face.querySelector("img")?.getAttribute("src")).toBe("https://a.example/p.png");
  const initials = render(<AuthorChip author={ANA} />).querySelector<HTMLElement>(".cv-face")!;
  expect(initials.style.width).toBe("var(--cv-author-face)");
  expect(initials.style.fontSize).toBe("calc(var(--cv-author-face) * 0.45)");
  // In a queued prompt's line of text it stays a mark inline with the words.
  const inline = render(<AuthorChip author={ANA} inline />).querySelector<HTMLElement>(".cv-face")!;
  expect(inline.style.width).toBe("16px");
});

test("the author face token derives from the grid scale, and the row estimate matches its line", () => {
  const css = readFileSync(new URL("./multiplayer.css", import.meta.url), "utf8");
  expect(css).toMatch(/--cv-author-face:\s*calc\(var\(--grid-base\) \* 5\);/);
  // The line is the 20 face (scaled with the interface) plus the 4 under it (model.ts authorHeight).
  const model = readFileSync(new URL("../model.ts", import.meta.url), "utf8");
  expect(model).toMatch(/const AUTHOR_FACE = 20;/);
  expect(model).toMatch(/Math\.max\(AUTHOR_LINE, AUTHOR_FACE \* chromeScale\) \+ AUTHOR_GAP/);
});

test("the header stacks three faces, then +N, and names everyone for screen readers", () => {
  const host = render(<PresenceStack viewing={[ANA, SAM, MEI, JORDAN]} />);
  expect(host.querySelectorAll(".cv-presence__person")).toHaveLength(3);
  expect([...host.querySelectorAll<HTMLElement>(".cv-presence__person")].map((person) => person.title)).toEqual([
    "Ana Ruiz",
    "Sam Okafor",
    "Mei Lin",
  ]);
  expect(host.querySelector(".cv-presence__more")?.textContent).toBe("+1");
  expect(host.querySelector(".cv-presence__label")?.textContent).toBe(
    "Also here: Ana Ruiz, Sam Okafor, Mei Lin, Jordan Blake",
  );
});

test("a reader alone sees no faces and no typing line", () => {
  const host = render(
    <>
      <PresenceStack viewing={[]} />
      <TypingLine typing={[]} />
    </>,
  );
  expect(host.innerHTML).toBe("");
});

test("the typing line names one, two, or several people", () => {
  expect(render(<TypingLine typing={[ANA]} />).querySelector(".cv-typing__words")?.textContent).toBe(
    "Ana Ruiz is typing…",
  );
  act(() => root?.render(<TypingLine typing={[ANA, SAM]} />));
  expect(dom!.window.document.querySelector(".cv-typing__words")?.textContent).toBe(
    "Ana Ruiz and Sam Okafor are typing…",
  );
  act(() => root?.render(<TypingLine typing={[ANA, SAM, MEI]} />));
  expect(dom!.window.document.querySelector(".cv-typing__words")?.textContent).toBe("Several people are typing…");
  expect(dom!.window.document.querySelectorAll(".cv-typing__dots > i")).toHaveLength(3);
});

test("answered by names the person", () => {
  expect(render(<AnsweredBy person={MEI} />).textContent).toBe("MAnswered by Mei Lin");
});

const settle = () =>
  act(async () => {
    for (let tick = 0; tick < 6; tick += 1) await Promise.resolve();
  });

test("an https picture the page cannot load is loaded inline by the host", async () => {
  const asked: unknown[] = [];
  setChipHost(async (method, params) => {
    asked.push([method, params]);
    return { src: "data:image/png;base64,AAAA" };
  });
  try {
    const host = render(
      <Face person={{ id: "guest:s.g1", name: "Priya Raman", avatar: "https://a.example/ok.png" }} />,
    );
    const img = host.querySelector("img")!;
    expect(img.getAttribute("src")).toBe("https://a.example/ok.png");
    expect(img.getAttribute("referrerpolicy")).toBe("no-referrer");
    // The page's policy refused the link (the app's `img-src data:`): the host loads it, no click spent.
    await act(async () => void img.dispatchEvent(new dom!.window.Event("error")));
    await settle();
    expect(host.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,AAAA");
    expect(asked).toEqual([["image.load", { src: "https://a.example/ok.png", auto: true }]]);
  } finally {
    setChipHost(undefined);
  }
});

test("an https picture neither the page nor the host loads draws the initials", async () => {
  setChipHost(async () => ({ ok: false }));
  try {
    const refused = render(
      <Face person={{ id: "guest:s.g2", name: "Tomás Ortega", avatar: "https://a.example/no.png" }} />,
    );
    await act(async () => void refused.querySelector("img")!.dispatchEvent(new dom!.window.Event("error")));
    await settle();
    expect(refused.querySelector("img")).toBeNull();
    expect(refused.querySelector(".cv-face")?.textContent).toBe("T");
  } finally {
    setChipHost(undefined);
  }
});
