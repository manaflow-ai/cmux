// Inline figures: a "+" before a count sits on the figures' centre, and a ticking clock keeps one
// width per shape, so a tick never moves its neighbours (Leo, 2026-11-09, on the hat's "+3 more  5m 41s").
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Clock, clockSizer, signed } from "./Typography";

test("a + right before a digit becomes the centred sign; other text is left alone", () => {
  expect(renderToStaticMarkup(<>{signed("+3 more")}</>)).toBe('<span class="ui-sign">+</span>3 more');
  expect(renderToStaticMarkup(<>{signed("edited a.rs · +12 more")}</>)).toBe(
    'edited a.rs · <span class="ui-sign">+</span>12 more',
  );
  expect(signed("ещё 3")).toBe("ещё 3");
  expect(signed("C++ code")).toBe("C++ code");
});

test("every clock of one shape reserves the same width", () => {
  for (const text of ["0s", "9s", "41s"]) expect(clockSizer(text)).toBe("00s");
  // "5m" ticks on to "5m 1s": both hold the minutes-and-seconds width.
  for (const text of ["1m", "5m 1s", "5m 41s", "59m 59s"]) expect(clockSizer(text)).toBe("00m 00s");
  // An hour clock ticks its seconds too ("1h 10m 9s" to "1h 10m 10s").
  for (const text of ["1h", "1h 3m", "1h 10m 9s", "12h 59m 59s"]) expect(clockSizer(text)).toBe("00h 00m 00s");
  expect(clockSizer("Running")).toBe("Running");
});

test("Clock draws its text over the hidden widest text of its shape", () => {
  expect(renderToStaticMarkup(<Clock className="x" text="5m 9s" />)).toBe(
    '<span class="ui-clock x" data-clock-size="00m 00s"><span class="ui-clock__text">5m 9s</span></span>',
  );
});
