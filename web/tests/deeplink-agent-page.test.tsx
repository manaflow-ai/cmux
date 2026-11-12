import { describe, expect, mock, test } from "bun:test";
import { isValidElement, type ReactNode } from "react";

import englishMessages from "../messages/en.json";

type MessageNode =
  | string
  | readonly MessageNode[]
  | { readonly [key: string]: MessageNode };

function lookup(root: MessageNode, path: string): MessageNode | undefined {
  return path.split(".").reduce<MessageNode | undefined>((node, key) => {
    if (node === undefined || typeof node === "string" || Array.isArray(node)) {
      return undefined;
    }
    return (node as { readonly [key: string]: MessageNode })[key];
  }, root);
}

const messages = englishMessages as unknown as MessageNode;

// next-intl's server translator needs a request; the page only ever asks it for
// a key and substitutes {params}, so the English catalog stands in for it.
mock.module("next-intl/server", () => ({
  getTranslations: async (namespace: string) => {
    const section = lookup(messages, namespace);
    return (key: string, values?: Record<string, string>) => {
      const template = section === undefined ? undefined : lookup(section, key);
      if (typeof template !== "string") throw new Error(`no message ${namespace}.${key}`);
      return template.replace(
        /\{(\w+)\}/g,
        (_match, name: string) => values?.[name] ?? "",
      );
    };
  },
}));

const { default: DeeplinkPage } = await import(
  "../app/[locale]/(landing)/deeplink/[kind]/page"
);

/** Every string the element tree renders as text, however deeply nested. */
function texts(node: ReactNode): string[] {
  if (typeof node === "string") return [node];
  if (Array.isArray(node)) return node.flatMap(texts);
  if (isValidElement<{ children?: ReactNode }>(node)) {
    return texts(node.props.children);
  }
  return [];
}

async function render(searchParams: Record<string, string | string[]>) {
  const element = await DeeplinkPage({
    params: Promise.resolve({ kind: "agent" }),
    searchParams: Promise.resolve(searchParams),
  });
  return texts(element);
}

describe("agent deeplink page", () => {
  test("a link with a message opens the session and shows the native URL", async () => {
    const rendered = await render({
      harness: "claude",
      session: "e8f63fd9-94e8-4878-bcd4-704659aba1f2",
      host: "cosmic-gray",
      message: "5cf944c9-b816-486a-a3aa-c89b3faea35f",
    });

    expect(rendered).toContain("Open in cmux");
    expect(rendered).toContain(
      "cmux://agent/claude/e8f63fd9-94e8-4878-bcd4-704659aba1f2?host=cosmic-gray&message=5cf944c9-b816-486a-a3aa-c89b3faea35f",
    );
    expect(rendered.join("\n")).not.toContain("unsupported parameters");
  });

  test("an unknown parameter warns by name and the session still opens", async () => {
    const rendered = await render({
      harness: "claude",
      session: "s1",
      host: "cosmic-gray",
      cwd: "/home/leo",
    });

    expect(rendered).toContain("Open in cmux");
    expect(rendered).toContain(
      "cmux ignores parameters it does not use: cwd. The session still opens.",
    );
    expect(rendered).toContain("cmux://agent/claude/s1?host=cosmic-gray");
    expect(rendered.join("\n")).not.toContain("/home/leo");
  });

  test("a session named twice is called a repeat, not a bad value", async () => {
    const rendered = await render({ harness: "claude", session: ["s1", "s2"] });

    expect(rendered).not.toContain("Open in cmux");
    expect(rendered).toContain("This link repeats parameters cmux will reject: session");
    expect(rendered.join("\n")).not.toContain("invalid parameter values");
    expect(rendered.join("\n")).not.toContain("missing required parameters: ");
  });

  test("a machine the app reads rides along in the native URL", async () => {
    const machine = "machine_0123456789abcdef0123456789abcdef";
    const rendered = await render({ harness: "claude", session: "s1", machine });

    expect(rendered).toContain("Open in cmux");
    expect(rendered).toContain(`cmux://agent/claude/s1?machine=${machine}`);
    expect(rendered.join("\n")).not.toContain("does not use");
  });

  test("a private reference says what it is and shows nothing to open", async () => {
    const rendered = await render({ id: "aid-0123456789abcdef0123" });
    const text = rendered.join("\n");

    expect(rendered).not.toContain("Open in cmux");
    expect(text).toContain("by a private reference");
    expect(text).not.toContain("missing required parameters");
    expect(text).not.toContain("cmux://agent");
    expect(text).not.toContain("aid-0123456789abcdef0123");
  });

  test("a malformed reference is just a link with no session", async () => {
    const rendered = await render({ id: "aid-not-hex" });

    expect(rendered).toContain(
      "This link is missing required parameters: harness, session",
    );
  });

  test("a link with no session says so and offers no Open", async () => {
    const rendered = await render({ harness: "claude" });

    expect(rendered).not.toContain("Open in cmux");
    expect(rendered).toContain(
      "This link is missing required parameters: session",
    );
    expect(rendered).toContain("cmux://agent");
  });
});
