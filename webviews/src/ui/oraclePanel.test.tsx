// The shared overlays' part of the refactor oracle's page state (oraclePanel.ts): an
// open overlay names its kind in the page's panels, and only while it is open.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ORACLE_STATE_ENABLED, readOracleState, type OracleStateTarget } from "../protocol/oracle-state";
import { useOraclePanel, type OraclePanelKind } from "./oraclePanel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const target: OracleStateTarget = { [ORACLE_STATE_ENABLED]: true, location: { hash: "" } };

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT", ORACLE_STATE_ENABLED])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    IS_REACT_ACT_ENVIRONMENT: true,
    [ORACLE_STATE_ENABLED]: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function Panel({ kind, open }: { kind: OraclePanelKind; open: boolean }) {
  useOraclePanel(kind, open);
  return null;
}

test("an open overlay is in the page's panels until it closes", async () => {
  root = createRoot(installDom());
  act(() =>
    root!.render(
      <>
        <Panel kind="menu" open />
        <Panel kind="dialog" open={false} />
      </>,
    ),
  );
  expect((await readOracleState(target)).panels).toEqual(["menu"]);
  act(() =>
    root!.render(
      <>
        <Panel kind="menu" open={false} />
        <Panel kind="dialog" open />
      </>,
    ),
  );
  expect((await readOracleState(target)).panels).toEqual(["dialog"]);
  act(() => root!.unmount());
  root = undefined;
  expect((await readOracleState(target)).panels).toEqual([]);
});
