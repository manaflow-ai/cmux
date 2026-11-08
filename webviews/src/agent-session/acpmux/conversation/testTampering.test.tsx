import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, AcpmuxTamperingReport } from "../model";
import { TurnActionsContext } from "./turnActions";
import { TestTampering, askWhyPrompt } from "./TestTampering";
import { hunkLines, tamperingForRows } from "./testTamperingModel";
import { resetTestTamperingState } from "./testTamperingStore";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTestTamperingState();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const row = (tampering: AcpmuxTamperingReport, id = "turn"): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind: "activity",
  items: [
    { kind: "tool", text: "Edit", tool: { id: "edit", title: "Edit", status: "completed", kind: "edit", tampering } },
  ],
});

test("aggregates one stable evidence list per turn and removes duplicate updates", () => {
  const report = {
    count: 1,
    files: [
      {
        path: "tests/auth.test.ts",
        findings: [
          {
            kind: "weakened-assertion",
            line: 8,
            message: "weakened",
            old: "expect(x).toEqual(1)",
            new: "expect(x).toBeTruthy()",
          },
        ],
      },
    ],
  };
  const evidence = tamperingForRows([row(report), row(report)]);
  expect(evidence).toHaveLength(1);
  expect(evidence[0]?.path).toBe("tests/auth.test.ts");
});

test("formats a restore request as the exact removed and added hunk lines", () => {
  const [finding] = tamperingForRows([
    row({
      count: 1,
      files: [
        {
          path: "tests/auth.rs",
          findings: [{ kind: "removed-test", line: 4, message: "removed", old: "#[test]\nfn test_auth() {}", new: "" }],
        },
      ],
    }),
  ]);
  expect(hunkLines(finding!)).toEqual(["-#[test]", "-fn test_auth() {}"]);
});

test("does not alarm for a failed edit and keeps identical evidence separate by turn", () => {
  const report = {
    count: 1,
    files: [
      {
        path: "tests/auth.test.ts",
        findings: [{ kind: "removed-test", line: 8, message: "removed", old: 'it("auth")', new: "" }],
      },
    ],
  };
  const failed = row(report, "failed");
  failed.items![0]!.tool!.status = "failed";
  const evidence = tamperingForRows([failed, row(report, "turn-a"), row(report, "turn-b")]);
  expect(evidence).toHaveLength(2);
});

test("includes exact evidence and a restore request in Ask why", () => {
  const [finding] = tamperingForRows([
    row({
      count: 1,
      files: [
        {
          path: "tests/auth.test.ts",
          findings: [
            {
              kind: "weakened-assertion",
              line: 8,
              message: "weakened",
              old: "expect(x).toEqual(1)",
              new: "expect(x).toBeTruthy()",
            },
          ],
        },
      ],
    }),
  ]);
  const prompt = askWhyPrompt([finding!]);
  expect(prompt).toContain("tests/auth.test.ts:8");
  expect(prompt).toContain("expect(x).toEqual(1)");
  expect(prompt).toContain("expect(x).toBeTruthy()");
  expect(prompt.toLowerCase()).toContain("restore");
});

test("persists disclosure and reports restore and Ask why action states", async () => {
  const rows = [
    row({
      count: 1,
      files: [
        {
          path: "tests/auth.test.ts",
          findings: [
            {
              kind: "weakened-assertion",
              line: 8,
              message: "weakened",
              old: "expect(x).toEqual(1)",
              new: "expect(x).toBeTruthy()",
            },
          ],
        },
      ],
    }),
  ];
  const restores: string[] = [];
  const prompts: string[] = [];
  const container = await render(
    <TurnActionsContext.Provider value={{ answer: async (prompt) => void prompts.push(prompt) }}>
      <TestTampering
        rows={rows}
        sessionId="session-a"
        onRestore={async (finding) => void restores.push(finding.path)}
      />
    </TurnActionsContext.Provider>,
  );
  const head = container.querySelector<HTMLButtonElement>(".acpmux-tampering-head")!;
  await act(async () => head.click());
  expect(head.getAttribute("aria-expanded")).toBe("true");
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-tampering-actions button")!.click());
  expect(restores).toEqual(["tests/auth.test.ts"]);
  const actions = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-tampering-actions button")];
  expect(actions[0]?.disabled).toBe(true);
  const ask = actions[1]!;
  await act(async () => ask.click());
  expect(prompts[0]).toContain("expect(x).toEqual(1)");
  expect(ask.disabled).toBe(true);
  if (root) await act(async () => root!.unmount());
  root = undefined;
  const remounted = await render(<TestTampering rows={rows} sessionId="session-a" />);
  expect(remounted.querySelector<HTMLButtonElement>(".acpmux-tampering-head")?.getAttribute("aria-expanded")).toBe(
    "true",
  );
});
