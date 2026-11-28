import { describe, expect, test } from "bun:test";
import type { AnyRouter } from "@tanstack/react-router";
import { renderToStaticMarkup } from "react-dom/server";
import { SettingsContext } from "./context";
import { StringMapEditor } from "./editors/StringMapEditor";
import type { SchemaRow } from "./schema";
import type { SettingsStore } from "./store";
import { t } from "./strings";

// A key and value list's empty line suggests what its keys and values are: a site for
// browser.siteEngines, a name and its text for agentPane.savedPrompts. First-run findings N7
// (2026-11-27): the Saved Prompts name field suggested "example.com".
function row(key: string): SchemaRow {
  return {
    key,
    path: key.split("."),
    section: "agents",
    group: { text: "Group", key: null },
    title: { text: "Map", key: null },
    help: null,
    summary: null,
    kind: "string_map",
    default: {},
    default_label: null,
    keywords: [],
    agent_settable: false,
    kept_on_reset_all: false,
    consumers: ["cmux-next"],
    page_hidden: false,
    validation: "",
    accepts: [],
    refuses: [],
  };
}

function placeholders(key: string): string[] {
  const html = renderToStaticMarkup(
    <SettingsContext.Provider value={{ store: {} as SettingsStore, router: {} as AnyRouter }}>
      <StringMapEditor row={row(key)} value={{}} disabled={false} labelId="label" />
    </SettingsContext.Provider>,
  );
  return [...html.matchAll(/<input[^>]*\splaceholder="([^"]*)"/g)].map((match) => match[1]!);
}

describe("key and value list placeholders", () => {
  test("saved prompts suggest a name and a prompt, never a site", () => {
    expect(placeholders("agentPane.savedPrompts")).toEqual([
      t("settingsWindow.agentSkills.newCommand.name"),
      t("settingsWindow.agentSkills.newCommand.prompt"),
    ]);
  });

  test("site engines keep the site example", () => {
    expect(placeholders("browser.siteEngines")).toEqual([t("settingsPage.hostPlaceholder")]);
  });

  test("another list suggests no site", () => {
    expect(placeholders("agents.env")).not.toContain(t("settingsPage.hostPlaceholder"));
  });
});
