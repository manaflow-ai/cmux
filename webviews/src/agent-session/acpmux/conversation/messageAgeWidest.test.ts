// A prompt's age keeps one width through its first hour (conversation.css `.cv-user__time::before`,
// MessageTime's data-age-widest), so the minute's new words replace the old in place. The width came
// from "59 minutes ago" alone, which is not the widest in every language: Polish "22 minuty temu" is
// longer than "59 minut temu", Russian "21 минуту назад" than "59 минут назад", Arabic's one minute
// than its 59. The reservation holds every wording the first hour writes (digits are tabular there,
// so one line per wording), and the hidden line lays them out so the widest sets the box.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { messageAge, messageAgeWidest } from "./relativeTime";

const MINUTE = 60_000;
const shape = (label: string) => label.replace(/\d/g, "0");

for (const locale of ["en-US", "pl", "ru", "ar", "de", "ja"])
  test(`${locale}: the reserved width covers every age of a prompt's first hour`, () => {
    const at = Date.UTC(2026, 10, 9, 12);
    const lines = new Set(messageAgeWidest(locale).split("\n").map(shape));
    for (let minute = 0; minute < 60; minute += 1) {
      const label = messageAge(at, at + minute * MINUTE + 30_000, locale);
      expect(lines.has(shape(label)), `${locale} ${minute}: ${label}`).toBe(true);
    }
    // One line per wording, never one per minute.
    expect(lines.size).toBeLessThanOrEqual(8);
  });

test("the hidden line lays out each wording on its own line", () => {
  const css = readFileSync(new URL("./conversation.css", import.meta.url), "utf8");
  const rule = /\.cv-user__time::before \{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(rule).toContain("content: attr(data-age-widest)");
  expect(rule).toMatch(/white-space:\s*pre;/);
});
