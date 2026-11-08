// l10n-allow-file: test fixture tool titles, commands and option names, not shipped UI.
// A Claude Bash permission drew "bash -c '" as its title, then the description, then the whole
// 30-line script raw, then two list rows ("1 Yes", "2 No, tell Claude what to do differently"):
// Leo 2026-10-21, "THIS IS NOT THE CORRECT UI AND IT ALSO LOOKS BAD". The card now reads as
// Claude Code desktop's prompt (permissions/prompt.ts): the description (or "Run command") as
// its title, the script's first line clamped with "Show full command", and Allow once, Always
// allow and Deny mapped onto the options the agent offered, answered by 1/2/3, Return and Esc.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html><div id=root></div><textarea id=elsewhere></textarea>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { PermissionCard } = await import("../src/agent-session/acpmux/PermissionCard");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const {
  commandPreview,
  optionButtonLabel,
  permissionAnswers,
  permissionKeyAction,
  permissionScopeText,
  permissionTitle,
  unwrapShell,
} = await import("../src/agent-session/acpmux/permissions/prompt");

const SCRIPT = [
  "bash -c '",
  "# Rebuild and check the pane",
  "set -euo pipefail",
  "cd webviews && bun run check",
  "echo '\\''done'\\''",
  "'",
].join("\n");
const claudeOptions: AcpmuxPermission["options"] = [
  { id: "allow", name: "Allow", kind: "allow_once", allow: true },
  { id: "always", name: "Always Allow", kind: "allow_always", allow: true },
  { id: "reject", name: "Reject", kind: "reject_once", allow: false },
];
const bash = (fields: Partial<AcpmuxPermission> = {}): AcpmuxPermission => ({
  permissionId: "p1",
  title: "`bash -c '",
  kind: "execute",
  command: SCRIPT,
  description: "Run the web checks",
  pending: true,
  options: claudeOptions,
  ...fields,
});

test("the title is the call's description, else Run command, never a command fragment", () => {
  expect(permissionTitle(bash(), translate)).toBe("Run the web checks");
  expect(permissionTitle(bash({ description: undefined }), translate)).toBe("Run command");
  expect(permissionTitle(bash({ description: "  \n" }), translate)).toBe("Run command");
  // A Codex command titled with its command line reads as a summary too.
  expect(permissionTitle({ permissionId: "c", title: "Run npm test", pending: true, options: [] }, translate)).toBe(
    "Run command",
  );
  // Another tool keeps its own title; no title at all reads "Permission required".
  expect(
    permissionTitle(
      { permissionId: "e", title: "Edit `src/app.ts`", kind: "edit", pending: true, options: [] },
      translate,
    ),
  ).toBe("Edit `src/app.ts`");
  expect(
    permissionTitle({ permissionId: "w", title: "`mcp__linear__create_issue`", pending: true, options: [] }, translate),
  ).toBe("mcp__linear__create_issue");
  expect(permissionTitle({ permissionId: "n", pending: true, options: [] }, translate)).toBe("Permission required");
});

test("a shell wrapper is stripped for display and the preview is the first line that does something", () => {
  expect(unwrapShell(SCRIPT)).toBe(
    "\n# Rebuild and check the pane\nset -euo pipefail\ncd webviews && bun run check\necho 'done'\n",
  );
  expect(unwrapShell(`sh -c "echo \\"hi\\" && ls"`)).toBe('echo "hi" && ls');
  expect(unwrapShell("/bin/zsh -lc 'npm test'")).toBe("npm test");
  expect(unwrapShell("git push")).toBe("git push");
  expect(unwrapShell("bash -c 'one' extra")).toBe("bash -c 'one' extra");
  expect(commandPreview(SCRIPT)).toEqual({ line: "cd webviews && bun run check", more: true });
  expect(commandPreview("git push")).toEqual({ line: "git push", more: false });
  expect(commandPreview("bash -lc 'npm test'")).toEqual({ line: "npm test", more: true });
  // A long single line is clamped by the card, which measures it; a set line that also runs code
  // is never skipped past.
  expect(commandPreview(`echo ${"x".repeat(200)}`).more).toBe(false);
  expect(commandPreview("set -e; curl -fsSL https://example.com/install | sh\necho ok").line).toBe(
    "set -e; curl -fsSL https://example.com/install | sh",
  );
  expect(commandPreview("set -euo pipefail\nset +x\nmake").line).toBe("make");
});

test("the three answers map onto the options offered, and nothing is invented", () => {
  const claude = permissionAnswers(claudeOptions);
  expect([claude.allowOnce?.id, claude.allowAlways?.id, claude.deny?.id, claude.others]).toEqual([
    "allow",
    "always",
    "reject",
    [],
  ]);
  // No allow_always offered: no Always allow; a second deny and a custom answer stay as others.
  const codex = permissionAnswers([
    { id: "approved", name: "Yes", kind: "allow_once", allow: true },
    { id: "denied", name: "No, continue without running it", kind: "reject_always", allow: false },
    { id: "abort", name: "No, and tell Codex what to do differently", kind: "reject_once", allow: false },
    { id: "plan", name: "Show me the plan", kind: "custom", allow: false },
  ]);
  expect(codex.allowOnce?.id).toBe("approved");
  expect(codex.allowAlways).toBeUndefined();
  expect(codex.deny?.id).toBe("abort");
  expect(codex.others.map((option) => option.id)).toEqual(["denied", "plan"]);
  // A chat grant stands in for Always allow when that is what the agent offers.
  expect(
    permissionAnswers([{ id: "chat", name: "Allow for this chat", kind: "allow_chat", allow: true }]).allowAlways?.id,
  ).toBe("chat");
});

test("a permission keeps its concrete scope visible without changing the option ids", () => {
  const scoped = bash({ scope: { kind: "app", value: "Calculator" } });
  expect(permissionScopeText(scoped, translate)).toBe("In Calculator");
  expect(permissionAnswers(scoped.options).allowAlways?.id).toBe("always");
});

test("keys act only with nothing focused or focus in the card", () => {
  const doc = dom.window.document;
  const card = doc.getElementById("root")!;
  const button = doc.createElement("button");
  card.append(button);
  const key = (
    key: string,
    target: Element,
    extra: { metaKey?: boolean; repeat?: boolean; isComposing?: boolean } = {},
  ) =>
    permissionKeyAction(
      { key, target, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...extra },
      card,
      false,
    );
  expect(["1", "2", "3", "Enter", "Escape"].map((name) => key(name, doc.body))).toEqual([
    "allow_once",
    "allow_always",
    "deny",
    "allow_once",
    "deny",
  ]);
  // The composer or any other field keeps its keys, Esc included.
  const field = doc.getElementById("elsewhere")!;
  expect(["1", "Enter", "Escape"].map((name) => key(name, field))).toEqual([undefined, undefined, undefined]);
  // A focused button keeps its own Return; a digit still answers.
  expect(key("Enter", button)).toBeUndefined();
  expect(key("3", button)).toBe("deny");
  // ⌘↩ allows once, as Claude desktop's "Allow ⌘↩", on a focused button too; never in a field.
  expect(key("Enter", doc.body, { metaKey: true })).toBe("allow_once");
  expect(key("Enter", button, { metaKey: true })).toBe("allow_once");
  expect(key("Enter", field, { metaKey: true })).toBeUndefined();
  // Other modifiers, repeats and input methods never answer.
  expect(key("1", doc.body, { metaKey: true })).toBeUndefined();
  expect(key("1", doc.body, { repeat: true })).toBeUndefined();
  expect(key("Enter", doc.body, { isComposing: true })).toBeUndefined();
  // With the feedback field open, Esc closes it and nothing else answers.
  const open = (name: string, target: Element) =>
    permissionKeyAction(
      { key: name, target, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false },
      card,
      true,
    );
  expect(open("Escape", doc.body)).toBe("closeFeedback");
  expect(open("1", doc.body)).toBeUndefined();
  expect(
    permissionKeyAction(
      { key: "Enter", target: doc.body, metaKey: true, ctrlKey: false, altKey: false, shiftKey: false },
      card,
      true,
    ),
  ).toBeUndefined();
  button.remove();
});

async function mount(permission: AcpmuxPermission, harness = "claude", fullAccessMode?: string) {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const answers: string[] = [];
  const denials: [string, string][] = [];
  await act(async () =>
    root.render(
      <PermissionCard
        permission={permission}
        harness={harness}
        fullAccessMode={fullAccessMode}
        onAnswer={(id) => answers.push(id)}
        onDenyWithFeedback={async (id, text) => {
          denials.push([id, text]);
          return true;
        }}
      />,
    ),
  );
  const press = (key: string, target: Element = dom.window.document.body) =>
    act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
  const click = (selector: string) =>
    act(async () =>
      (host.querySelector(selector) as HTMLElement).dispatchEvent(
        new dom.window.MouseEvent("click", { bubbles: true }),
      ),
    );
  const buttons = () =>
    [...host.querySelectorAll(".acpmux-permission-buttons button")].map((b) => b.getAttribute("aria-label"));
  return { host, answers, denials, press, click, buttons, unmount: () => act(async () => root.unmount()) };
}

test("the card draws the title, the clamped command and the three buttons, and expands", async () => {
  const card = await mount(bash());
  expect(card.host.querySelector(".acpmux-permission-request-label")?.textContent).toBe("Run the web checks");
  expect(card.host.textContent).not.toContain("bash -c '");
  expect(card.host.querySelector(".acpmux-permission-command-preview")?.textContent).toBe(
    "cd webviews && bun run check",
  );
  expect(card.host.querySelector(".ui-glass")).not.toBeNull();
  expect(card.buttons()).toEqual(["Deny", "Always allow", "Allow once"]);
  await card.click(".acpmux-permission-command-toggle");
  expect(card.host.querySelector(".acpmux-permission-command-full")?.textContent).toBe(SCRIPT);
  expect(card.host.querySelector(".acpmux-permission-command-toggle")?.textContent).toBe("Hide full command");
  await card.unmount();
});

test("the card labels the scoped target once, on its line, and every answer is described by it", async () => {
  const card = await mount(bash({ permissionId: "scoped", scope: { kind: "app", value: "Calculator" } }));
  expect(card.host.querySelector(".acpmux-permission-scope")?.textContent).toBe("In Calculator");
  const target = card.host.querySelector<HTMLElement>(".acpmux-permission-scope span")!;
  for (const label of ["Allow once", "Always allow", "Deny"]) {
    const button = card.host.querySelector(`[aria-label="${label}"]`)!;
    expect(button.textContent).not.toContain("Calculator");
    expect(button.getAttribute("aria-describedby")).toBe(target.id);
  }
  await card.unmount();
});

// Leo 2026-10-25: "the allow button, like this, it shouldn't be encompassing so much ... this other,
// like, thing shouldn't be the same thing." Always allow held the whole session rule and the rule
// repeated as a line under Deny.
const RULE =
  "Allow Read(//Users/you/media/reel/**), Bash(rm -f /Users/you/media/reel/*.tmp), Bash(ffmpeg:*) for this session";
test("a long rule shows once, on the scope line, never in a button, and describes Always allow", async () => {
  const card = await mount(
    bash({ permissionId: "rule", rule: RULE, scope: { kind: "directory", value: "/Users/you/media/reel" } }),
  );
  expect(card.buttons()).toEqual(["Deny", "Always allow", "Allow once"]);
  const buttons = [...card.host.querySelectorAll(".acpmux-permission-buttons button")];
  expect(buttons.map((button) => button.querySelector(".acpmux-permission-action-label")?.textContent)).toEqual([
    "Deny",
    "Always allow",
    "Allow once",
  ]);
  for (const button of buttons) expect(button.textContent).not.toContain("ffmpeg");
  const lines = card.host.querySelectorAll(".acpmux-permission-scope");
  expect(lines.length).toBe(1);
  expect(lines[0]!.textContent).toBe(`In /Users/you/media/reel · ${RULE}`);
  expect(lines[0]!.getAttribute("title")).toBe(`In /Users/you/media/reel · ${RULE}`);
  // The rule is drawn exactly once in the whole card.
  expect(card.host.textContent!.split(RULE).length - 1).toBe(1);
  const [target, rule] = [...lines[0]!.querySelectorAll("span")];
  const always = card.host.querySelector('[aria-label="Always allow"]')!;
  expect(always.getAttribute("aria-describedby")).toBe(`${target!.id} ${rule!.id}`);
  expect(always.getAttribute("title")).toBe(RULE);
  expect(card.host.querySelector('[aria-label="Allow once"]')?.getAttribute("aria-describedby")).toBe(target!.id);
  await card.unmount();
});

test("long agent labels get short buttons from their ACP kind, in one row, and their text moves out", async () => {
  const card = await mount(
    bash({
      permissionId: "codex4",
      rule: undefined,
      options: [
        { id: "approved", name: "Yes", kind: "allow_once", allow: true },
        {
          id: "session",
          name: "Yes, and don't ask again for commands that start with `npm run`",
          kind: "allow_always",
          allow: true,
        },
        { id: "abort", name: "No, and tell Codex what to do differently", kind: "reject_once", allow: false },
        { id: "denied", name: "No, continue without running it", kind: "reject_always", allow: false },
      ],
    }),
    "codex",
  );
  expect(card.buttons()).toEqual(["Always deny", "Deny", "Always allow", "Allow once"]);
  expect(card.host.querySelectorAll(".acpmux-permission-buttons").length).toBe(1);
  // Sized to their labels: no equal-width grid and no per-card answer count drives the row.
  expect(card.host.querySelector<HTMLElement>(".acpmux-permission-buttons")!.getAttribute("style")).toBeNull();
  // The Always allow's own long name is its scope, on the line; the other's is its hover title.
  expect(card.host.querySelector(".acpmux-permission-scope")?.textContent).toBe(
    "Yes, and don't ask again for commands that start with `npm run`",
  );
  expect(card.host.querySelector('[aria-label="Always deny"]')?.getAttribute("title")).toBe(
    "No, continue without running it",
  );
  const alwaysDeny = card.host.querySelector('[aria-label="Always deny"]')!;
  expect(dom.window.document.getElementById(alwaysDeny.getAttribute("aria-describedby")!)?.textContent).toBe(
    "No, continue without running it",
  );
  await card.click('[aria-label="Always deny"]');
  expect(card.answers).toEqual(["denied"]);
  await card.unmount();
});

test("an extra option keeps a short agent name, else its kind's label, else its name", () => {
  const taken = new Set(["Allow once", "Always allow", "Deny"]);
  const label = (name: string, kind?: string) =>
    optionButtonLabel({ id: "o", name, kind, allow: false }, translate, taken);
  expect(label("Show me the plan", "custom")).toBe("Show me the plan");
  expect(label("No, continue without running it", "reject_always")).toBe("Always deny");
  // A kind another button already names is numbered, never the agent's long text.
  expect(label("No, and tell the agent what to do instead", "reject_once")).toBe("Deny 2");
  expect(label("Allow Read(/Users/you/project/**) for this session", "allow_always")).toBe("Always allow 2");
  expect(
    optionButtonLabel(
      { id: "o", name: "Allow Read(/Users/you/other/**) for this session", kind: "allow_always", allow: true },
      translate,
      new Set([...taken, "Always allow 2"]),
    ),
  ).toBe("Always allow 3");
  // Only a kind the pane has no word for keeps its long name, which the button cuts.
  expect(label("Show me the whole plan before running anything", "custom")).toBe(
    "Show me the whole plan before running anything",
  );
  expect(
    optionButtonLabel(
      { id: "o", name: "Yes, and allow edits to every file in this folder", kind: "allow_once", allow: true },
      translate,
      new Set(),
    ),
  ).toBe("Allow once");
});

test("1, 2, Return answer; 3 and Esc open the feedback field; Esc closes it; its send denies with the text", async () => {
  let card = await mount(bash());
  await card.press("1");
  await card.press("2");
  expect(card.answers).toEqual(["allow"]);
  await card.unmount();

  card = await mount(bash({ permissionId: "p2" }));
  await card.press("2");
  expect(card.answers).toEqual(["always"]);
  await card.unmount();

  card = await mount(bash({ permissionId: "p3" }));
  await card.press("Enter");
  expect(card.answers).toEqual(["allow"]);
  await card.unmount();

  card = await mount(bash({ permissionId: "p4" }));
  // Typing in another field never answers.
  await card.press("1", dom.window.document.getElementById("elsewhere")!);
  expect(card.answers).toEqual([]);
  await card.press("3");
  const field = card.host.querySelector("textarea")!;
  expect(field.getAttribute("placeholder")).toBe("Tell Claude what to do differently");
  expect(card.host.querySelector(".acpmux-permission-buttons")).toBeNull();
  await card.press("Escape", field);
  expect(card.host.querySelector("textarea")).toBeNull();
  await card.press("Escape");
  const reopened = card.host.querySelector("textarea")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setter.call(reopened, "Use the fleet instead");
    reopened.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await card.click(".acpmux-permission-feedback-send");
  expect(card.denials).toEqual([["reject", "Use the fleet instead"]]);
  expect(card.answers).toEqual([]);
  await card.unmount();
});

test("an ask without an Always allow option draws no such button and 2 does nothing", async () => {
  const card = await mount(
    bash({
      permissionId: "p5",
      options: [
        { id: "allow", name: "Allow", kind: "allow_once", allow: true },
        { id: "reject", name: "Reject", kind: "reject_once", allow: false },
      ],
    }),
  );
  expect(card.buttons()).toEqual(["Deny", "Allow once"]);
  await card.press("2");
  expect(card.answers).toEqual([]);
  await card.unmount();
});

test("the answer row is content-width buttons, never stretched to equal cells", async () => {
  const { readFileSync } = await import("node:fs");
  const css = readFileSync(new URL("../src/agent-session/acpmux/styles.css", import.meta.url), "utf8");
  const rule = (selector: string) => {
    const at = css.indexOf(`${selector}{`);
    expect(at).toBeGreaterThanOrEqual(0);
    return css.slice(at, css.indexOf("}", at));
  };
  const row = rule(".acpmux-permission-ask .acpmux-permission-buttons");
  expect(row).toContain("display:flex");
  expect(row).not.toContain("grid");
  expect(row).not.toContain("1fr");
  const button = rule(".acpmux-permission-ask .acpmux-permission-buttons button");
  expect(button).toContain("flex:none");
  // Centred, so the label sits level with its Esc or ⌘ ↩ keycaps.
  expect(button).toContain("align-items:center");
  // Deny keeps the leading edge, the allows the trailing one, as Claude desktop's card.
  expect(rule(".acpmux-permission-ask .acpmux-permission-allows")).toContain("margin-inline-start:auto");
});

// Leo 2026-11-04: "a temporary one-time sort of ask for, like if for whatever reason there's the
// bypass permissions, it doesn't bypass every single thing ... We need to have that proper
// rendering as well." In Bypass permissions an ask that still comes says the mode doesn't cover it.
test("in the chat's highest mode an ask that still comes says the mode doesn't cover it, once", async () => {
  const stillAsks: AcpmuxPermission = {
    permissionId: "still-asks",
    kind: "fetch",
    title: "Open developer.apple.com/account in the browser",
    pending: true,
    options: [
      { id: "allow_once", name: "Answer", kind: "allow_once", allow: true },
      { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
    ],
  };
  const line = (host: Element) => host.querySelectorAll(".acpmux-permission-one-time");

  const plain = await mount(stillAsks);
  expect(line(plain.host)).toHaveLength(0);
  await plain.unmount();

  const bypass = await mount(stillAsks, "claude", "Bypass permissions");
  expect(line(bypass.host)).toHaveLength(1);
  expect(line(bypass.host)[0]!.textContent).toBe(
    translate("permission.fullAccessStillAsks", { mode: "Bypass permissions" }),
  );
  expect(line(bypass.host)[0]!.textContent).toContain("Bypass permissions");
  expect(bypass.buttons()).toEqual([translate("permission.deny"), translate("permission.allowOnce")]);
  await bypass.press("1");
  expect(bypass.answers).toEqual(["allow_once"]);
  await bypass.unmount();

  // No one-time allow offered: the line says only that the ask needs an answer.
  const denyOnly = await mount(
    { ...stillAsks, permissionId: "deny-only", options: [stillAsks.options[1]!] },
    "codex",
    "Full access",
  );
  expect(line(denyOnly.host)[0]!.textContent).toBe(
    translate("permission.fullAccessStillAsksNoOnce", { mode: "Full access" }),
  );
  await denyOnly.unmount();

  // An answered ask (a record) draws no line.
  const answered = await mount(
    { ...stillAsks, permissionId: "answered", pending: false },
    "claude",
    "Bypass permissions",
  );
  expect(line(answered.host)).toHaveLength(0);
  await answered.unmount();
});
