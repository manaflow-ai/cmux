import { expect, test } from "bun:test";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { TurnActionsContext } from "../conversation/turnActions";
import { TripwireRecap, TripwireStatus, type Tripwire } from "./TripwireStatus";

const items: Tripwire[] = [
  {
    name: "Login error",
    path: "tests/login.test.ts",
    verdict: "backed",
    toolCallId: "t1",
    command: "bun test tests/login.test.ts",
  },
  { name: "Wrong password", path: "tests/auth.test.ts", verdict: "failed" },
  { name: "Typecheck", path: "src", verdict: "none" },
];

const renderTripwires = (node: ReactNode) =>
  renderToStaticMarkup(
    <TurnActionsContext.Provider value={{ showCall: () => true }}>{node}</TurnActionsContext.Provider>,
  );

test("empty tripwires render nothing", () => {
  expect(renderToStaticMarkup(<TripwireStatus items={[]} />)).toBe("");
});

test("header status keeps all states and never reports completion with red or grey checks", () => {
  const html = renderTripwires(<TripwireStatus items={items} />);
  expect(html).toContain('data-tripwire-count="3"');
  expect(html).toContain('data-tripwire-unresolved="2"');
  expect(html).toContain('data-tripwire-complete="false"');
  expect(html).toContain('data-tripwire-verdict="backed"');
  expect(html).toContain('data-tripwire-verdict="failed"');
  expect(html).toContain('data-tripwire-verdict="none"');
  expect(html).toContain('href="#tool-t1"');
});

test("tool-linked checks stay plain when no transcript navigation is available", () => {
  const html = renderToStaticMarkup(<TripwireStatus items={[items[0]!]} />);
  expect(html).not.toContain("<a ");
  expect(html).toContain('data-tripwire-verdict="backed"');
});

test("status caps the visible list while retaining hidden failures in completion", () => {
  const many = Array.from({ length: 12 }, (_, index) => ({
    name: `Check ${index}`,
    path: `tests/${index}.test.ts`,
    verdict: index === 11 ? ("failed" as const) : ("backed" as const),
  }));
  const html = renderTripwires(<TripwireStatus items={many} />);
  expect(html).toContain('data-tripwire-count="8"');
  expect(html).toContain('data-tripwire-total="12"');
  expect(html).toContain('data-tripwire-unresolved="1"');
  expect(html).toContain('data-tripwire-complete="false"');
  expect(html).not.toContain("Check 8");
});

test("closing recap names the unresolved path and preserves the failed verdict", () => {
  const html = renderTripwires(<TripwireRecap items={items} />);
  expect(html).toContain("tests/auth.test.ts");
  expect(html).toContain('data-tripwire-verdict="failed"');
  expect(html).toContain('data-tripwire-verdict="none"');
  expect(html).toContain('data-tripwire-complete="false"');
});
