// React 19.2.3's own behaviour behind scripts/check-effect-event-wrappers.ts: an effect event in a
// plain `React.memo` (fiber tag 15) or `forwardRef` (tag 11) component keeps its first render's
// function, because commitBeforeMutationEffects hands an event its new function for `case 0:` only
// (`case 11: case 15: break;`). A plain component, `memo(fn, compare)` (fn in its own tag-0 fiber)
// and useCommittedEvent in a memo component see each render's props.
//
// Each component reads `label` from an effect that re-runs on `id`; the test renders
// { id: 1, label: "first" } and then { id: 2, label: "second" }.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act, forwardRef, memo, useEffect, useEffectEvent, type ComponentType } from "react";
import { useCommittedEvent } from "../src/agent-session/acpmux/useCommittedEvent";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/", virtualConsole: new VirtualConsole() });
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const { createRoot } = await import("react-dom/client");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Props = { id: number; label: string; seen: string[] };

function Plain({ id, label, seen }: Props) {
  const read = useEffectEvent(() => seen.push(label));
  useEffect(() => {
    read();
  }, [id]);
  return null;
}
const Memo = memo(function Memo({ id, label, seen }: Props) {
  const read = useEffectEvent(() => seen.push(label));
  useEffect(() => {
    read();
  }, [id]);
  return null;
});
const MemoCompared = memo(
  function MemoCompared({ id, label, seen }: Props) {
    const read = useEffectEvent(() => seen.push(label));
    useEffect(() => {
      read();
    }, [id]);
    return null;
  },
  (before, after) => before.id === after.id && before.label === after.label,
);
const Forwarded = forwardRef<unknown, Props>(function Forwarded({ id, label, seen }, _ref) {
  const read = useEffectEvent(() => seen.push(label));
  useEffect(() => {
    read();
  }, [id]);
  return null;
});
const MemoCommitted = memo(function MemoCommitted({ id, label, seen }: Props) {
  const read = useCommittedEvent(() => seen.push(label));
  useEffect(() => {
    read();
  }, [id, read]);
  return null;
});

function labelsSeen(Component: ComponentType<Props>): string[] {
  const seen: string[] = [];
  const root = createRoot(dom.window.document.body.appendChild(dom.window.document.createElement("div")));
  act(() => root.render(<Component id={1} label="first" seen={seen} />));
  act(() => root.render(<Component id={2} label="second" seen={seen} />));
  act(() => root.unmount());
  return seen;
}

const fixed =
  "React now hands an effect event its new function in this fiber too: React has fixed it, so scripts/check-effect-event-wrappers.ts (and its check:effect-event-wrappers step) can go";

test("useEffectEvent in a plain React.memo or a forwardRef component keeps its first render's function", () => {
  expect(labelsSeen(Memo), `React.memo (tag 15): ${fixed}`).toEqual(["first", "first"]);
  expect(labelsSeen(Forwarded as ComponentType<Props>), `forwardRef (tag 11): ${fixed}`).toEqual(["first", "first"]);
});

test("useEffectEvent in a plain component or memo(fn, compare) sees each render's props", () => {
  expect(labelsSeen(Plain)).toEqual(["first", "second"]);
  expect(labelsSeen(MemoCompared)).toEqual(["first", "second"]);
});

test("useCommittedEvent in a plain React.memo component sees each render's props", () => {
  expect(labelsSeen(MemoCommitted)).toEqual(["first", "second"]);
});
