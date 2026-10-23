import path from "node:path";
import ts from "typescript";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** Reads of layout or of what a frame shows: in a frame callback they see the frame before its
 *  ResizeObservers and paint. */
const LAYOUT_READS = new Set([
  "getBoundingClientRect",
  "getClientRects",
  "getComputedStyle",
  "elementFromPoint",
  "scrollTop",
  "scrollLeft",
  "scrollHeight",
  "scrollWidth",
  "offsetTop",
  "offsetLeft",
  "offsetHeight",
  "offsetWidth",
  "clientHeight",
  "clientWidth",
  "innerText",
]);

const isFrameCall = (node: ts.Node): node is ts.CallExpression =>
  ts.isCallExpression(node) &&
  ((ts.isIdentifier(node.expression) && node.expression.text === "requestAnimationFrame") ||
    (ts.isPropertyAccessExpression(node.expression) && node.expression.name.text === "requestAnimationFrame"));

const isFunction = (node: ts.Node): node is ts.FunctionLikeDeclaration =>
  ts.isArrowFunction(node) || ts.isFunctionExpression(node) || ts.isFunctionDeclaration(node);

/** The name a function is bound to: `function tick() {}`, `const tick = () => {}`. */
function boundName(fn: ts.FunctionLikeDeclaration): string | undefined {
  if (ts.isFunctionDeclaration(fn)) return fn.name?.text;
  const parent = fn.parent;
  if (ts.isVariableDeclaration(parent) && ts.isIdentifier(parent.name)) return parent.name.text;
  if (ts.isFunctionExpression(fn)) return fn.name?.text;
  return undefined;
}

/** A layout read directly in `fn`'s body (nested functions are their own callbacks), from position
 *  `after` on; writes such as `scroller.scrollTop = 0` are not reads. */
function readsLayout(fn: ts.Node, after = -1): boolean {
  let found = false;
  const visit = (node: ts.Node) => {
    if (found || (node !== fn && isFunction(node))) return;
    const name = ts.isPropertyAccessExpression(node)
      ? node.name.text
      : ts.isIdentifier(node) && ts.isCallExpression(node.parent) && node.parent.expression === node
        ? node.text
        : undefined;
    if (name && LAYOUT_READS.has(name)) {
      const parent = node.parent;
      const written =
        ts.isBinaryExpression(parent) &&
        parent.left === node &&
        parent.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
        parent.operatorToken.kind <= ts.SyntaxKind.LastAssignment;
      if (!written && node.pos >= after) found = true;
    }
    ts.forEachChild(node, visit);
  };
  visit(fn);
  return found;
}

/**
 * A browser test reads layout after the frame has painted (test/support/paintedFrames.ts), never in
 * a requestAnimationFrame callback, which runs before the frame's ResizeObservers and paint and so
 * can see a state nobody saw. Flagged: a callback that reschedules itself (a per-frame sampler); a
 * frame callback that reads layout; a named function that awaits a frame (`new Promise((resolve) =>
 * requestAnimationFrame(resolve))`), whose caller reads in the same microtask; a function that awaits
 * such a frame inline and then reads layout. A frame callback
 * that has to read there says why in a `// raf-read: <reason>` comment on one of the two lines above.
 */
export function checkFrameReadsSource(file: string, text: string): string[] {
  const name = path.relative(root, file);
  if (!/^import\b[^;]*\bfrom "playwright";/m.test(text)) return [];
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const lines = text.split("\n");
  const excused = (node: ts.Node) => {
    const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line;
    return lines.slice(Math.max(0, line - 2), line + 1).some((each) => /\/\/ raf-read: \S/.test(each));
  };
  const errors: string[] = [];
  const flag = (node: ts.Node, what: string) => {
    if (excused(node)) return;
    const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
    errors.push(
      `${name}:${line}: ${what}; read after the frame paints with window.cmuxAfterPaint or window.cmuxPaintFrame (installPaintedFrames from ./support/paintedFrames), or say why in a "// raf-read: <reason>" comment`,
    );
  };
  const visit = (node: ts.Node) => {
    if (isFrameCall(node)) {
      const callback = node.arguments[0];
      if (callback && ts.isIdentifier(callback)) {
        // A sampler: the call sits inside the function it schedules.
        for (let up: ts.Node | undefined = node.parent; up; up = up.parent)
          if (isFunction(up) && boundName(up) === callback.text) {
            flag(node, `samples every frame in a requestAnimationFrame callback (${callback.text})`);
            break;
          }
        // A frame awaiter: `const frame = () => new Promise((resolve) => requestAnimationFrame(resolve))`,
        // or the same wait over two frames, `requestAnimationFrame(() => requestAnimationFrame(resolve))`.
        let executor: ts.Node | undefined = node.parent;
        while (executor && !(isFunction(executor) && executor.parameters[0]?.name.getText(source) === callback.text))
          executor = executor.parent;
        const promise = executor?.parent;
        if (
          executor &&
          isFunction(executor) &&
          executor.parameters[0]?.name.getText(source) === callback.text &&
          promise &&
          ts.isNewExpression(promise) &&
          promise.expression.getText(source) === "Promise"
        ) {
          let owner: ts.Node | undefined = promise.parent;
          while (owner && !isFunction(owner)) owner = owner.parent;
          if (owner && boundName(owner))
            flag(node, `awaits a frame in ${boundName(owner)}(), so its caller reads before the frame paints`);
          // `await new Promise(...)` then a read: the read runs in a microtask of the frame's callbacks.
          // A read before the wait is of the frame before.
          else if (owner && ts.isAwaitExpression(promise.parent) && readsLayout(owner, promise.parent.end))
            flag(node, "awaits a frame and then reads layout before the frame paints");
        }
      } else if (callback && isFunction(callback) && readsLayout(callback)) {
        flag(node, "reads layout in a requestAnimationFrame callback");
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return errors;
}
