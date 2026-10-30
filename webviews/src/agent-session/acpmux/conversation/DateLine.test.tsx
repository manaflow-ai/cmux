// l10n-allow-file: expected localized dates in regression tests, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { currentLanguage, setPaneLanguage } from "../i18n";
import { DateLine } from "./DateLine";
import { timestampText } from "./timestamps";

const now = new Date(2026, 9, 29, 12).getTime();
const cases = [0, 1, 10];
const scope = globalThis as Record<string, unknown>;
let cleanup: (() => void) | undefined;
let root: Root | undefined;

function mountDom() {
  const dom = new JSDOM("<!doctype html><main></main>");
  const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"];
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  const language = currentLanguage();
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  cleanup = () => {
    setPaneLanguage(language);
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  };
  const container = dom.window.document.querySelector("main")!;
  root = createRoot(container);
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  cleanup?.();
  cleanup = undefined;
});

function expected(at: number, days: number, language: string) {
  const time = new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }).format(at);
  if (days <= 1) return `${language === "fr" ? ["aujourd’hui", "hier"][days] : ["今日", "昨日"][days]} ${time}`;
  return new Intl.DateTimeFormat(language, {
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(at);
}

test.each(cases)("a %i-day-old separator mounts in French", async (days) => {
  const container = mountDom();
  const at = new Date(2026, 9, 29 - days, 9, 15).getTime();
  setPaneLanguage("fr");
  await act(async () => root!.render(<DateLine row={{ id: "date", version: 1, kind: "date", at }} now={now} />));
  expect(container.textContent).toBe(expected(at, days, "fr"));
  expect(container.querySelector("time")?.dateTime).toBe(new Date(at).toISOString());
});

test.each(cases)("a %i-day-old separator follows a live French-to-Japanese switch", async (days) => {
  const container = mountDom();
  const at = new Date(2026, 9, 29 - days, 9, 15).getTime();
  setPaneLanguage("fr");
  await act(async () => root!.render(<DateLine row={{ id: "date", version: 1, kind: "date", at }} now={now} />));
  const element = container.querySelector("time");
  await act(async () => setPaneLanguage("ja"));
  expect(container.textContent).toBe(expected(at, days, "ja"));
  expect(container.querySelector("time")).toBe(element);
  expect(element?.dateTime).toBe(new Date(at).toISOString());
});

test.each(["fr", "ja", "ar", "en-US"])("older dates use %s date-time ordering and the requested timezone", (locale) => {
  const at = Date.UTC(2024, 9, 19, 23, 15);
  const options: Intl.DateTimeFormatOptions = {
    timeZone: "Asia/Tokyo",
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  };
  expect(timestampText(at, { now, locale, timeZone: options.timeZone })).toBe(
    new Intl.DateTimeFormat(locale, options).format(at),
  );
});
