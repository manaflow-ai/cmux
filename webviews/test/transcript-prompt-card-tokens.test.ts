// The prompt's edit box, the recap card, the turn error card and the Cloud repository recovery
// line draw from tokens that exist: a var() whose property no stylesheet defines falls back (or
// draws nothing) in every theme, as `--agent-error` / `--agent-success` did under
// `.cv-repo-recovery` (always #d66 and #5aaf83). Their corners are the grid's radii, and a sent
// thumbnail and a reply's image share one media radius.
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { describe, expect, test } from "bun:test";

const src = path.resolve(import.meta.dir, "../src");

function cssFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return cssFiles(full);
    return name.endsWith(".css") ? [full] : [];
  });
}

const all = cssFiles(src)
  .map((file) => readFileSync(file, "utf8"))
  .join("\n");
const defined = new Set([...all.matchAll(/(--[\w-]+)\s*:/g)].map((match) => match[1]!));
const conversation = readFileSync(path.join(src, "agent-session/acpmux/conversation/conversation.css"), "utf8").replace(
  /\/\*[\s\S]*?\*\//g,
  "",
);

/// Every rule in conversation.css whose selector names `pattern`, as [selector, body].
function rules(pattern: RegExp): [string, string][] {
  return [...conversation.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .map((match): [string, string] => [match[1]!.trim(), match[2]!])
    .filter(([selector]) => pattern.test(selector));
}

const CARDS = /\.cv-(repo-recovery(--\w+)?|recap|user__edit|user__versions|turn-error(--card|--rail)?)(?![\w-])/;

describe("transcript prompt and card tokens", () => {
  test("every custom property they read is defined", () => {
    const missing = rules(CARDS).flatMap(([selector, body]) =>
      [...body.matchAll(/var\((--[\w-]+)/g)]
        .map((match) => match[1]!)
        .filter((name) => !defined.has(name))
        .map((name) => `${selector}: ${name}`),
    );
    expect(missing).toEqual([]);
  });

  test("their corners are the grid's radii, never a literal", () => {
    const literal = rules(CARDS).flatMap(([selector, body]) =>
      [...body.matchAll(/border-radius:\s*([^;]+);/g)]
        .map((match) => match[1]!.trim())
        .filter((value) => /^\d/.test(value))
        .map((value) => `${selector}: ${value}`),
    );
    expect(literal).toEqual([]);
  });

  test("a card adds no outer margin", () => {
    const margins = rules(/\.cv-(repo-recovery|recap|turn-error--card)\s*(\{|,|$|\[)/).flatMap(([selector, body]) =>
      [...body.matchAll(/(?:^|;|\s)(margin(?:-[\w-]+)?):\s*([^;]+);/g)]
        .filter((match) => match[2]!.trim() !== "0")
        .map((match) => `${selector}: ${match[1]} ${match[2]!.trim()}`),
    );
    expect(margins).toEqual([]);
  });

  test("sent thumbnails and reply images share the media radius", () => {
    for (const selector of [/\.cv-user__images img/, /^\.cv-img$/, /\.cv-user__image-placeholder/]) {
      const bodies = rules(selector).map(([, body]) => body);
      expect(bodies.some((body) => /border-radius:\s*var\(--cv-media-radius\)/.test(body))).toBe(true);
    }
  });
});
