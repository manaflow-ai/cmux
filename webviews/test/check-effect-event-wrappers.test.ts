// The effect-event wrapper rule (scripts/check-effect-event-wrappers.ts): `useEffectEvent` in a plain
// `React.memo` or a `forwardRef` component keeps its first render's function (React 19.2.3), so it is
// named; test/effect-event-wrappers-react.test.tsx pins that React behaviour itself.
import { expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { checkEffectEventWrappersSource } from "../scripts/check-effect-event-wrappers";

const imports = `import { forwardRef, memo, useEffect, useEffectEvent } from "react";\nimport * as React from "react";\n`;
const check = (body: string) => checkEffectEventWrappersSource("a.tsx", imports + body);
// An event read from an effect that re-runs on `id`, so it must see each render's `label`.
const body = `{
  const read = useEffectEvent(() => log(label));
  useEffect(() => read(), [id]);
  return null;
}`;

test("memo without a comparator fails, with the line, the component and the replacement", () => {
  const errors = check(`export const Row = memo(function Row({ id, label }) ${body});`);
  expect(errors).toHaveLength(1);
  expect(errors[0]).toContain("a.tsx:4: useEffectEvent in Row, a React.memo component with no comparator");
  expect(errors[0]).toContain("useCommittedEvent (src/agent-session/acpmux/useCommittedEvent.ts)");
  expect(errors[0]).toContain("case 11: case 15: break");
  expect(check(`export const Row = React.memo(({ id, label }) => ${body});`)).toHaveLength(1);
});

test("memo with a comparator passes: React renders the function in its own tag-0 fiber", () => {
  expect(check(`export const Row = memo(function Row({ id, label }) ${body}, (a, b) => a.id === b.id);`)).toEqual([]);
});

test("forwardRef fails, with or without memo around it, and with a comparator too", () => {
  const forward = check(`export const Row = forwardRef(function Row({ id, label }, ref) ${body});`);
  expect(forward).toHaveLength(1);
  expect(forward[0]).toContain("useEffectEvent in Row, a forwardRef component (fiber tag 11)");
  expect(check(`export const Row = React.forwardRef(({ id, label }, ref) => ${body});`)).toHaveLength(1);
  expect(check(`export const Row = memo(forwardRef(function Row({ id, label }, ref) ${body}));`)).toHaveLength(1);
  expect(
    check(`export const Row = memo(forwardRef(function Row({ id, label }, ref) ${body}), () => false);`),
  ).toHaveLength(1);
});

test("a named function wrapped later in the file fails", () => {
  expect(check(`function Row({ id, label }) ${body}\nexport default memo(Row);`)).toHaveLength(1);
  expect(check(`const Row = ({ id, label }) => ${body};\nexport const Wrapped = forwardRef(Row);`)).toHaveLength(1);
  expect(check(`function Row({ id, label }, ref) ${body}\nexport default memo(forwardRef(Row));`)).toHaveLength(1);
  // An aliased import is still React's memo.
  expect(
    checkEffectEventWrappersSource(
      "a.tsx",
      `import { memo as pure, useEffect, useEffectEvent } from "react";\nfunction Row({ id, label }) ${body}\nexport default pure(Row);`,
    ),
  ).toHaveLength(1);
  // Wrapped with a comparator, it passes.
  expect(check(`function Row({ id, label }) ${body}\nexport default memo(Row, (a, b) => a.id === b.id);`)).toEqual([]);
});

test("a plain function component and a hook pass", () => {
  expect(check(`export function Row({ id, label }) ${body}`)).toEqual([]);
  expect(check(`export const Row = ({ id, label }) => ${body};`)).toEqual([]);
  expect(check(`export function useRead(id, label) ${body}`)).toEqual([]);
});

test("an event used only directly in a [] effect passes; a listener it registers there does not", () => {
  const mount = (effect: string) =>
    check(`export const Row = memo(function Row({ label }) {
  const read = useEffectEvent(() => log(label));
  ${effect}
  return null;
});`);
  expect(mount("useEffect(() => { read(); }, []);")).toEqual([]);
  expect(mount("React.useLayoutEffect(() => read(), []);")).toEqual([]);
  // A listener runs long after mount, with the first render's function.
  expect(mount(`useEffect(() => { const on = () => read(); addEventListener("x", on); }, []);`)).toHaveLength(1);
  expect(mount(`useEffect(() => { addEventListener("x", read); }, []);`)).toHaveLength(1);
  expect(mount("useEffect(() => read(), [label]);")).toHaveLength(1);
  expect(mount("useEffect(() => read());")).toHaveLength(1);
  expect(mount("const run = () => read();")).toHaveLength(1);
});

test("the mount-only marker passes the call on its line or the line below", () => {
  expect(
    check(`export const Row = memo(function Row({ id, label }) {
  // effect-event: mount-only (read once, when the row first commits)
  const read = useEffectEvent(() => log(label));
  useEffect(() => read(), [id]);
  return null;
});`),
  ).toEqual([]);
  expect(
    check(`export const Row = memo(function Row({ id, label }) {
  const read = useEffectEvent(() => log(label)); // effect-event: mount-only
  useEffect(() => read(), [id]);
  return null;
});`),
  ).toEqual([]);
});

test("a memo or forwardRef component that calls a same-file hook using useEffectEvent fails", () => {
  const hook = `function useRead(id, label) {
  const read = useEffectEvent(() => log(label));
  useEffect(() => read(), [id]);
}
function useRow(id, label) { useRead(id, label); }
`;
  const direct = check(
    `${hook}export const Row = memo(function Row({ id, label }) { useRead(id, label); return null; });`,
  );
  expect(direct).toHaveLength(1);
  expect(direct[0]).toContain("useRead uses useEffectEvent and is called by Row, a React.memo component");
  // Through another same-file hook, and from a forwardRef component.
  expect(
    check(`${hook}export const Row = forwardRef(({ id, label }, ref) => { useRow(id, label); return null; });`),
  ).toHaveLength(1);
  // A plain component, or memo with a comparator, may call it.
  expect(check(`${hook}export function Row({ id, label }) { useRow(id, label); return null; }`)).toEqual([]);
  expect(
    check(`${hook}export const Row = memo(({ id, label }) => { useRead(id, label); return null; }, () => false);`),
  ).toEqual([]);
  // A hook whose events are mount-only is fine in any component.
  expect(
    check(`function useOnce(label) { const read = useEffectEvent(() => log(label)); useEffect(() => read(), []); }
export const Row = memo(({ label }) => { useOnce(label); return null; });`),
  ).toEqual([]);
});

test("every useEffectEvent in webviews/src passes", () => {
  const src = path.join(import.meta.dir, "../src");
  const errors: string[] = [];
  let sites = 0;
  function scan(directory: string) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) scan(file);
      else if (/\.[cm]?[jt]sx?$/.test(entry.name)) {
        const text = readFileSync(file, "utf8");
        sites += text.match(/\buseEffectEvent\(/g)?.length ?? 0;
        errors.push(...checkEffectEventWrappersSource(file, text));
      }
    }
  }
  scan(src);
  expect(errors).toEqual([]);
  // The rule has real sites to read; if they all go, so can the rule.
  expect(sites).toBeGreaterThan(0);
});
