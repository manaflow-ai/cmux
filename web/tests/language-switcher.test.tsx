import { describe, expect, mock, test } from "bun:test";
import type { ReactElement } from "react";

const replace = mock(() => undefined);
const push = mock(() => undefined);
const writtenCookies: string[] = [];
let currentLocale = "en";

// Spread the real modules: bun swaps a mocked module for the whole process,
// and a partial mock breaks other suites in the shared run.
const actualIntl = await import("next-intl");
const actualNavigation = await import("../i18n/navigation");

mock.module("next-intl", () => ({
  ...actualIntl,
  useLocale: () => currentLocale,
}));

mock.module("../i18n/navigation", () => ({
  ...actualNavigation,
  usePathname: () => "/pricing",
  useRouter: () => ({ push, replace }),
}));

const { LanguageSwitcher } = await import(
  "../app/[locale]/components/language-switcher"
);

describe("footer language switcher", () => {
  test("navigates the document instead of a client-side transition", () => {
    expect(switchLocaleTo("ja")).toEqual(["/ja/pricing"]);
    expect(replace).not.toHaveBeenCalled();
    expect(push).not.toHaveBeenCalled();
  });

  test("keeps the current query string and hash on the new locale", () => {
    const assigned = switchLocaleTo("zh-CN", {
      search: "?plan=team",
      hash: "#faq",
    });

    expect(assigned).toEqual(["/zh-CN/pricing?plan=team#faq"]);
  });

  test("drops the prefix when switching back to the default locale", () => {
    expect(switchLocaleTo("en", { from: "zh-CN" })).toEqual(["/pricing"]);
  });

  test("persists the new locale so the unprefixed default path sticks", () => {
    switchLocaleTo("en", { from: "ja" });

    expect(writtenCookies).toEqual(["NEXT_LOCALE=en;path=/;samesite=lax"]);
  });

  test("ignores a selection of the locale already in use", () => {
    expect(switchLocaleTo("en")).toEqual([]);
    expect(writtenCookies).toEqual([]);
  });
});

function switchLocaleTo(
  locale: string,
  location: { search?: string; hash?: string; from?: string } = {},
): string[] {
  const assigned: string[] = [];
  writtenCookies.length = 0;
  currentLocale = location.from ?? "en";
  replace.mockClear();
  push.mockClear();

  const previousWindow = (globalThis as { window?: unknown }).window;
  const previousDocument = (globalThis as { document?: unknown }).document;
  (globalThis as { window?: unknown }).window = {
    location: {
      search: location.search ?? "",
      hash: location.hash ?? "",
      assign: (url: string) => {
        assigned.push(url);
      },
    },
  };
  (globalThis as { document?: unknown }).document = {
    set cookie(value: string) {
      writtenCookies.push(value);
    },
  };

  try {
    findSelect(LanguageSwitcher()).props.onChange({ target: { value: locale } });
  } finally {
    (globalThis as { window?: unknown }).window = previousWindow;
    (globalThis as { document?: unknown }).document = previousDocument;
  }

  return assigned;
}

function findSelect(node: unknown): ReactElement<{
  onChange: (event: { target: { value: string } }) => void;
}> {
  if (!isElement(node)) {
    throw new Error("language switcher did not render an element");
  }
  if (node.type === "select") {
    return node as ReactElement<{
      onChange: (event: { target: { value: string } }) => void;
    }>;
  }
  const children = (node.props as { children?: unknown }).children;
  for (const child of Array.isArray(children) ? children : [children]) {
    if (!isElement(child)) {
      continue;
    }
    try {
      return findSelect(child);
    } catch {
      continue;
    }
  }
  throw new Error("language switcher did not render a select");
}

function isElement(node: unknown): node is ReactElement {
  return (
    typeof node === "object" &&
    node !== null &&
    "type" in node &&
    "props" in node
  );
}
