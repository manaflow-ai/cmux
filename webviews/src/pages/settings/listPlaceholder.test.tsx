import { describe, expect, test } from "bun:test";
import type { AnyRouter } from "@tanstack/react-router";
import { renderToStaticMarkup } from "react-dom/server";
import { SettingsContext } from "./context";
import { HostListEditor } from "./editors/HostListEditor";
import type { SchemaRow } from "./schema";
import type { SettingsStore } from "./store";
import { t } from "./strings";

// A list row's empty field shows the row's own placeholder (the schema's `placeholder`), a host
// list falls back to its host example, and a free-text list without one shows none: never the
// host example "example.com" on a list of words or rules (a1018, 2026-11-06).
function row(kind: "host_list" | "string_list", placeholder?: SchemaRow["placeholder"]): SchemaRow {
  return {
    key: "test.list",
    path: ["test", "list"],
    section: "general",
    group: { text: "Group", key: null },
    title: { text: "List", key: null },
    help: null,
    summary: null,
    kind,
    default: [],
    default_label: null,
    keywords: [],
    agent_settable: false,
    kept_on_reset_all: false,
    consumers: ["cmux-next"],
    page_hidden: false,
    validation: "",
    accepts: [],
    refuses: [],
    ...(placeholder === undefined ? {} : { placeholder }),
  };
}

function placeholderOf(schemaRow: SchemaRow): string | null {
  const html = renderToStaticMarkup(
    <SettingsContext.Provider value={{ store: {} as SettingsStore, router: {} as AnyRouter }}>
      <HostListEditor row={schemaRow} value={[]} disabled={false} labelId="label" />
    </SettingsContext.Provider>,
  );
  const match = /<input[^>]*\splaceholder="([^"]*)"/.exec(html);
  return match ? match[1]! : null;
}

describe("list placeholders", () => {
  test("a free-text list shows its own placeholder", () => {
    expect(placeholderOf(row("string_list", { text: "Add a word or phrase", key: null }))).toBe("Add a word or phrase");
  });

  test("a free-text list without one shows none, never the host example", () => {
    expect(placeholderOf(row("string_list"))).toBeNull();
    expect(placeholderOf(row("string_list", null))).toBeNull();
  });

  test("a host list keeps its host example unless the row names its own", () => {
    expect(placeholderOf(row("host_list"))).toBe(t("settingsPage.hostPlaceholder"));
    expect(placeholderOf(row("host_list", { text: "devbox.local", key: null }))).toBe("devbox.local");
  });
});
