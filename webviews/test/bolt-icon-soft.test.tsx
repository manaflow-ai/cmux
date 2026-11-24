// The Fast-mode bolt is the soft one Leo asked for (2026-10-20): "I want a cute freaking lightning
// bolt icon ... I don't want it to be like a sharp one. I think the slightly blobby one is a bit
// nice, but I don't think we want as blobby as ChatGPT does it." A filled bolt whose corners a
// round-joined stroke of the same ink rounds off, inside the same 16 px box, and every surface that
// draws a bolt (model button, `/` menu) uses this one glyph.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { BoltIcon } from "../src/agent-session/acpmux/BoltIcon";

const html = renderToStaticMarkup(<BoltIcon />);

test("the bolt is filled, not a thin outline", () => {
  expect(html).toContain('fill="currentColor"');
  expect(html).not.toContain('fill="none"');
});

test("its corners are rounded by a round-joined stroke, slightly, not ChatGPT-round", () => {
  expect(html).toContain('stroke-linejoin="round"');
  const width = Number(/stroke-width="([\d.]+)"/.exec(html)?.[1]);
  expect(width).toBeGreaterThanOrEqual(1.25);
  expect(width).toBeLessThanOrEqual(2);
});

test("the stroke keeps the bolt inside its 16 px box", () => {
  const width = Number(/stroke-width="([\d.]+)"/.exec(html)?.[1]);
  const d = /<path d="([^"]+)"/.exec(html)?.[1] ?? "";
  // Absolute points of the path (M x y, implicit L, h, l, L, H, Z), walked by hand.
  const tokens = d.match(/[A-Za-z]|-?\d*\.?\d+/g) ?? [];
  let x = 0;
  let y = 0;
  let cmd = "";
  const xs: number[] = [];
  const ys: number[] = [];
  for (let i = 0; i < tokens.length;) {
    const t = tokens[i]!;
    if (/[A-Za-z]/.test(t)) {
      cmd = t;
      i += 1;
      continue;
    }
    const n = (k: number) => Number(tokens[i + k]);
    if (cmd === "M" || cmd === "L") [x, y] = [n(0), n(1)];
    else if (cmd === "l") [x, y] = [x + n(0), y + n(1)];
    else if (cmd === "H") x = n(0);
    else if (cmd === "h") x += n(0);
    i += cmd === "H" || cmd === "h" ? 1 : 2;
    if (cmd === "M") cmd = "L";
    xs.push(x);
    ys.push(y);
  }
  expect(xs.length).toBeGreaterThanOrEqual(6);
  const pad = width / 2;
  expect(Math.min(...xs) - pad).toBeGreaterThanOrEqual(0);
  expect(Math.min(...ys) - pad).toBeGreaterThanOrEqual(0);
  expect(Math.max(...xs) + pad).toBeLessThanOrEqual(16);
  expect(Math.max(...ys) + pad).toBeLessThanOrEqual(16);
});
