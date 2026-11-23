// l10n-allow-file: test fixtures.
// A received message's unverified mark (UnverifiedMark.tsx): "Claimed to be NAME, not proven" for a
// sender that only named itself, none for one the host's sender token verified, and for a program
// acpmux saw send it (incomingMessage.ts `senderProgram`), what acpmux checked: the program, the
// machine its send named, that no agent was proven, and the program's path.
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { incomingPrompt } from "./incomingMessage";
import { programMarkText, UnverifiedMark } from "./UnverifiedMark";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

/// The line drawn in a page, as the transcript draws it (its hooks read the page's stores).
async function renderLine(message: Parameters<typeof IncomingMessageLine>[0]["message"]): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const page = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(page)) saved.set(key, scope[key]);
  Object.assign(scope, page);
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(<IncomingMessageLine id="m-1" message={message} onOpen={() => undefined} />);
  });
  return container;
}

const decode = (html: string) =>
  html
    .replace(/&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, "&");

test("a sender that only named itself keeps the plain mark", () => {
  const markup = renderToStaticMarkup(<UnverifiedMark />);
  expect(markup).toContain('aria-label="Sender not verified"');
  expect(markup).not.toContain("is-program");
});

test("a sender's own name is its claim, not proven", () => {
  const markup = decode(renderToStaticMarkup(<UnverifiedMark claimed="ci-watch" />));
  expect(markup).toContain('aria-label="Claimed to be ci-watch, not proven"');
  expect(markup).toContain('title="Claimed to be ci-watch, not proven"');
  // A blank claim is none.
  expect(renderToStaticMarkup(<UnverifiedMark claimed="  " />)).toContain('aria-label="Sender not verified"');
});

const readMessage = (provenance: Record<string, unknown>) => {
  const prompt = incomingPrompt("#40611 conflicts with feat-cmux-next", { _meta: { provenance } });
  if (prompt?.kind !== "message") throw new Error("not a message");
  return prompt.message;
};
const namedSender = {
  kind: "agent_message",
  from: "fromAgent",
  fromName: "outbox-relay",
  to: "s-1",
  transport: "unix",
};

test("a named sender verified by the host token draws no mark", async () => {
  const verified = readMessage({ ...namedSender, verified: true, verifiedBy: "host-token" });
  expect(verified.unverified).not.toBe(true);
  const line = await renderLine(verified);
  expect(line.querySelector(".cv-received__from")?.textContent).toBe("outbox-relay");
  expect(line.querySelector(".cv-unverified")).toBeNull();
  // A sender record acpmux wrote says the same.
  const recorded = readMessage({
    ...namedSender,
    verified: true,
    verifiedBy: "host-token",
    sender: { verification: "verified", verifiedBy: "host-token" },
  });
  expect(recorded.unverified).not.toBe(true);
});

test("the same name with no token, or a label no daemon gave, is a claim", async () => {
  for (const provenance of [
    { ...namedSender, verifiedBy: "host-token" },
    { ...namedSender, verified: true, verifiedBy: "elsewhere" },
  ]) {
    expect(readMessage(provenance).unverified).toBe(true);
  }
  const line = await renderLine(readMessage(namedSender));
  expect(line.querySelector(".cv-unverified")?.getAttribute("aria-label")).toBe(
    "Claimed to be outbox-relay, not proven",
  );
});

test("a program's mark says acpmux checked it, and no agent was proven", () => {
  const program = { name: "next-autoland", path: "/Users/cmux/Projects/leo-workspace/tools/next-autoland" };
  expect(programMarkText(translate, program)).toEqual({
    label: "Program checked by cmux: next-autoland",
    title:
      "Program checked by cmux: next-autoland\nNot proven to be an agent\n/Users/cmux/Projects/leo-workspace/tools/next-autoland",
  });
  const markup = decode(renderToStaticMarkup(<UnverifiedMark program={program} />));
  expect(markup).toContain("cv-unverified is-program");
  expect(markup).toContain('aria-label="Program checked by cmux: next-autoland"');
});

test("a peer-forwarded program names the machine its send claimed", () => {
  expect(programMarkText(translate, { name: "stall-reconciler", host: "build-box" })).toEqual({
    label: "Program checked by cmux: stall-reconciler on build-box",
    title: "Program checked by cmux: stall-reconciler on build-box\nNot proven to be an agent",
  });
});

test("the received line names the program, not an unverified sender", async () => {
  const unverified = { kind: "unverified", to: "s-1", transport: "unix", verified: false };
  const read = (provenance: Record<string, unknown>) => {
    const prompt = incomingPrompt("Merged #23727", { _meta: { provenance } });
    if (prompt?.kind !== "message") throw new Error("not a message");
    return prompt.message;
  };
  const named = await renderLine(read({ ...unverified, program: { name: "next-autoland" } }));
  expect(named.querySelector(".cv-received__from")?.textContent).toBe("next-autoland");
  expect(named.querySelector(".cv-unverified.is-program")?.getAttribute("aria-label")).toBe(
    "Program checked by cmux: next-autoland",
  );
  expect(named.textContent).not.toContain("Unverified sender");
});

test("a malformed program is none: the line is an unverified sender's", async () => {
  const provenance = {
    kind: "unverified",
    to: "s-1",
    transport: "unix",
    verified: false,
    program: { name: "two\nlines" },
  };
  const prompt = incomingPrompt("Merged #23727", { _meta: { provenance } });
  if (prompt?.kind !== "message") throw new Error("not a message");
  const line = await renderLine(prompt.message);
  expect(line.querySelector(".cv-received__from")?.textContent).toBe("Unverified sender");
  expect(line.querySelector(".cv-unverified")?.getAttribute("aria-label")).toBe("Sender not verified");
  expect(line.querySelector(".is-program")).toBeNull();
});
