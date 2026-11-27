// A gallery still must not depend on a wall-clock timer racing the capture. The stage is ready once
// its DOM has been quiet for a moment (frame/main.ts `markReadyWhenStill`), then the variant's play
// runs and settles; a scenario that changes what it shows on a `setTimeout` or `setInterval` outside
// its play is captured at whichever tick the timer reached by then, so a still flips between states
// from run to run (agent-pane.blank-load-fade: 11 of 14 timed stills blank on base, and a review
// flagged unchanged pairs as changed by a PR).
//
// So every timer in a `*.gallery.ts(x)` file is either play code (a `play` property's function, a
// `Play`-typed function, or one that takes the play context), or carries a `gallery-capture:` note on
// its line or in the comment just above it naming the capture moment: the play that waits for the
// timer's end state, or why the timer cannot change a still (it runs only after a click, it is not
// drawn). The note is a declaration a reviewer reads, not an escape: a play that waits is the fix.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";
import { galleryFiles } from "../scripts/gallery/entries";

const NOTE = "gallery-capture:";
const TIMERS = new Set(["setTimeout", "setInterval"]);

function timerName(call: ts.CallExpression): string | undefined {
  const callee = call.expression;
  if (ts.isIdentifier(callee) && TIMERS.has(callee.text)) return callee.text;
  if (ts.isPropertyAccessExpression(callee) && TIMERS.has(callee.name.text)) return callee.name.text;
  return undefined;
}

const isFunction = (node: ts.Node): node is ts.FunctionLikeDeclaration =>
  ts.isArrowFunction(node) ||
  ts.isFunctionExpression(node) ||
  ts.isFunctionDeclaration(node) ||
  ts.isMethodDeclaration(node);

const typeText = (type: ts.TypeNode | undefined, source: ts.SourceFile) => type?.getText(source) ?? "";

/** A function the stage runs as a play step: the capture waits for whatever it waits for. */
function isPlayFunction(fn: ts.FunctionLikeDeclaration, source: ts.SourceFile): boolean {
  const parent = fn.parent;
  if (ts.isPropertyAssignment(parent) && parent.name.getText(source) === "play") return true;
  if (ts.isVariableDeclaration(parent) && /\bPlay\b/.test(typeText(parent.type, source))) return true;
  if (/\bPlay\b/.test(typeText(fn.type, source))) return true;
  return fn.parameters.some((parameter) => {
    if (/\bPlayContext\b/.test(typeText(parameter.type, source))) return true;
    if (ts.isIdentifier(parameter.name)) return parameter.name.text === "ctx";
    // `({ waitFor, document }) => ...`: the play context, destructured.
    return (
      ts.isObjectBindingPattern(parameter.name) &&
      parameter.name.elements.some((element) => /^(waitFor|click|hover|press|find)$/.test(element.name.getText(source)))
    );
  });
}

function inPlay(node: ts.Node, source: ts.SourceFile): boolean {
  for (let at: ts.Node | undefined = node.parent; at; at = at.parent)
    if (isFunction(at) && isPlayFunction(at, source)) return true;
  return false;
}

/**
 * A `gallery-capture:` note on the timer's line, or in the comment just above the timer's statement
 * or a statement around it (a handler or effect that schedules several steps declares them once).
 */
function declared(call: ts.CallExpression, source: ts.SourceFile, lines: string[]): boolean {
  const lineOf = (node: ts.Node) => source.getLineAndCharacterOfPosition(node.getStart(source)).line;
  const noteAbove = (line: number) => {
    for (let at = line - 1; at >= 0 && /^\s*(\/\/|\/\*|\*)/.test(lines[at]!); at--)
      if (lines[at]!.includes(NOTE)) return true;
    return false;
  };
  if (lines[lineOf(call)]!.includes(NOTE)) return true;
  for (let at: ts.Node = call; !ts.isSourceFile(at); at = at.parent) if (noteAbove(lineOf(at))) return true;
  return false;
}

/** `file:line timer` for each timer that is neither play code nor declared. */
export function undeclaredTimers(file: string, text = fs.readFileSync(file, "utf8")): string[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const lines = text.split("\n");
  const found: string[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isCallExpression(node)) {
      const name = timerName(node);
      if (name && !inPlay(node, source) && !declared(node, source, lines)) {
        const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
        found.push(`${path.relative(path.resolve(import.meta.dir, ".."), file)}:${line} ${name}`);
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return found;
}

describe("gallery timers declare their capture moment", () => {
  test("every timer in a gallery file is play code or names its capture moment", () => {
    const found = galleryFiles().flatMap((file) => undeclaredTimers(file));
    if (found.length)
      console.error(
        `A gallery scenario changes state on a timer the capture races. Add a play that waits for the end ` +
          `state (ctx.waitFor), or a \`${NOTE} <why the still is fixed>\` note above the timer:\n  ${found.join("\n  ")}`,
      );
    expect(found).toEqual([]);
  });

  test("the check sees a mount timer and accepts play code and notes", () => {
    const fixture = [
      'import { useEffect, useState } from "react";',
      "function Stage() {",
      "  const [step, setStep] = useState(0);",
      "  useEffect(() => {",
      "    const timer = window.setTimeout(() => setStep(1), 400);",
      "    return () => clearTimeout(timer);",
      "  }, []);",
      "  // gallery-capture: only after the Replay click; the still is the first frame.",
      "  const replay = () => setTimeout(() => setStep(2), 10);",
      "  return null;",
      "}",
      "export default {",
      "  variants: { a: { play: async (ctx) => { await new Promise((r) => setTimeout(r, 50)); } } },",
      "  b: { play: ({ waitFor }) => waitFor(() => setInterval(() => {}, 1) && true) },",
      "};",
    ].join("\n");
    expect(undeclaredTimers(path.join(import.meta.dir, "fixture.gallery.tsx"), fixture)).toEqual([
      "test/fixture.gallery.tsx:5 setTimeout",
    ]);
  });
});
