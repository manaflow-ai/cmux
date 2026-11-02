/**
 * Static checks for the cross-surface UI review rules.
 *
 * The checker is deliberately conservative. It reports only copy and row contracts that can be
 * proved from source; geometry belongs to the shared grid-lines browser check. Existing debt is
 * recorded in ui-review-allowlist.jsonl and every entry names an owner. The allowlist is a ratchet
 * that warns and never fails (style ratchets are warnings): a finding not present in it is reported
 * as a warning, and entries for fixed findings are reported as stale. Only a broken checker (an
 * exception while scanning) exits nonzero.
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";

export type Rule =
  | "narration"
  | "redundant-open"
  | "multi-space"
  | "repeated-leading-label"
  | "mixed-row-weight"
  | "hard-coded-agent-icon";

export interface Finding {
  rule: Rule;
  file: string;
  line: number;
  fingerprint: string;
  message: string;
}

export interface AllowlistEntry {
  rule: Rule;
  file: string;
  fingerprint: string;
  owner: string;
  why: string;
}

const HERE = dirname(fileURLToPath(import.meta.url));
export const WEBVIEWS = join(HERE, "..");
export const SOURCE_ROOT = join(WEBVIEWS, "src");
export const ALLOWLIST = join(HERE, "ui-review-allowlist.jsonl");

const SOURCE_EXTENSIONS = new Set([".ts", ".tsx", ".css", ".xcstrings"]);
const EXCLUDED = /(?:\.test\.|\.gallery\.|\.experiment\.|(?:node_modules|generated))/;

/** Patterns are short, user-visible status narration. Add new patterns only with a concrete UI example. */
export const NARRATION_PATTERNS: readonly [RegExp, string][] = [
  [/\bread after this (?:turn|step)\b/i, "explains when a message will be read"],
  [/\b(?:started|created) sub-session\b/i, "narrates an internal sub-session event"],
  [/\bthe user sees it under your chat\b/i, "narrates where an internal result appears"],
  [/\bworks in parallel\b/i, "narrates implementation detail instead of state"],
];

const TYPE_LABELS = new Set([
  "agent",
  "account",
  "command",
  "file",
  "model",
  "project",
  "session",
  "subagent",
  "sub-agent",
  "task",
  "tool",
]);

const ROW_CLASS = /(?:^|[-_])(row|item|line|card|agent|session|subagent|tool)(?:$|[-_])/i;
const HARNESS_ICON = /^agent\./i;

function lineAt(text: string, offset: number): number {
  return text.slice(0, offset).split("\n").length;
}

function relativeFile(file: string): string {
  return relative(WEBVIEWS, file).replaceAll("\\", "/");
}

function sourceFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== "node_modules" && entry.name !== "generated") sourceFiles(full, out);
      continue;
    }
    if (SOURCE_EXTENSIONS.has(full.slice(full.lastIndexOf("."))) && !EXCLUDED.test(full)) out.push(full);
  }
  return out;
}

function sourceKind(file: string): ts.ScriptKind {
  return file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
}

function parseSource(file: string, text: string): ts.SourceFile {
  return ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, sourceKind(file));
}

function propertyName(node: ts.PropertyName | undefined): string | undefined {
  if (!node) return undefined;
  if (ts.isIdentifier(node) || ts.isStringLiteral(node)) return node.text;
  return undefined;
}

function jsxName(node: ts.JsxTagNameExpression): string {
  return ts.isIdentifier(node) ? node.text : node.getText();
}

function openingElement(element: ts.JsxElement | ts.JsxSelfClosingElement): ts.JsxOpeningLikeElement {
  return ts.isJsxElement(element) ? element.openingElement : element;
}

function jsxAttribute(element: ts.JsxElement | ts.JsxSelfClosingElement, name: string): ts.JsxAttribute | undefined {
  const props = openingElement(element).attributes.properties;
  return props.find(
    (prop): prop is ts.JsxAttribute => ts.isJsxAttribute(prop) && ts.isIdentifier(prop.name) && prop.name.text === name,
  );
}

function attributeText(element: ts.JsxElement | ts.JsxSelfClosingElement, name: string): string | undefined {
  const attr = jsxAttribute(element, name);
  if (!attr?.initializer) return undefined;
  if (ts.isStringLiteral(attr.initializer)) return attr.initializer.text;
  if (ts.isJsxExpression(attr.initializer) && attr.initializer.expression) {
    const expression = attr.initializer.expression;
    if (ts.isStringLiteral(expression) || ts.isNoSubstitutionTemplateLiteral(expression)) return expression.text;
  }
  return undefined;
}

function ancestors(node: ts.Node): ts.Node[] {
  const result: ts.Node[] = [];
  for (let parent = node.parent; parent; parent = parent.parent) result.push(parent);
  return result;
}

/** Attributes whose value a person reads or hears; className, type, name and the like are not copy. */
const COPY_ATTRIBUTE = /^(?:title|placeholder|alt|label|aria-label|aria-description|aria-valuetext|aria-placeholder)$/i;

function isUiLiteral(node: ts.StringLiteral | ts.NoSubstitutionTemplateLiteral): boolean {
  const parent = node.parent;
  if (ts.isPropertyAssignment(parent)) {
    const name = propertyName(parent.name);
    return Boolean(name && /^(?:label|title|text|description|placeholder|ariaLabel|aria-label|alt)$/i.test(name));
  }
  // A literal reaches the screen only through ?:, && and ||/?? into a JSX child or a copy attribute; a comparison
  // operand (`message === "Read after this turn"`) or another call's argument never renders.
  let current: ts.Node = node;
  while (ts.isParenthesizedExpression(current.parent) || isRenderedBranch(current)) current = current.parent;
  const slot = current.parent;
  const host = ts.isJsxExpression(slot) ? slot.parent : slot;
  if (ts.isJsxAttribute(host)) return ts.isIdentifier(host.name) && COPY_ATTRIBUTE.test(host.name.text);
  return ts.isJsxExpression(slot) && (ts.isJsxElement(host) || ts.isJsxFragment(host));
}

function isRenderedBranch(node: ts.Node): boolean {
  const parent = node.parent;
  if (ts.isConditionalExpression(parent)) return node !== parent.condition;
  if (!ts.isBinaryExpression(parent)) return false;
  const operator = parent.operatorToken.kind;
  return (
    operator === ts.SyntaxKind.BarBarToken ||
    operator === ts.SyntaxKind.QuestionQuestionToken ||
    (operator === ts.SyntaxKind.AmpersandAmpersandToken && node === parent.right)
  );
}

function normalizeCopy(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function candidateCopy(node: ts.Node, translations: Map<string, string>): string | undefined {
  if (ts.isJsxText(node)) return node.getText();
  if (!(ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node))) return undefined;
  const call = node.parent;
  if (
    ts.isCallExpression(call) &&
    call.arguments[0] === node &&
    ts.isIdentifier(call.expression) &&
    /^(?:t|translate|i18n)$/i.test(call.expression.text)
  ) {
    return translations.get(node.text);
  }
  if (isUiLiteral(node)) return node.text;
  return undefined;
}

function collectTranslations(file: string, text: string): Array<{ value: string; offset: number }> {
  if (!file.endsWith(".xcstrings")) return [];
  const values: Array<{ value: string; offset: number }> = [];
  const valuePattern = /^\s*"value"\s*:\s*("(?:\\.|[^"\\])*")/gm;
  for (const match of text.matchAll(valuePattern)) {
    try {
      const value = JSON.parse(match[1]!) as unknown;
      if (typeof value === "string") values.push({ value, offset: match.index ?? 0 });
    } catch {
      // The catalog check owns malformed JSON; this lint skips the malformed value.
    }
  }
  return values;
}

function translationMap(file: string, text: string): Map<string, string> {
  const map = new Map<string, string>();
  if (!file.endsWith(".xcstrings")) return map;
  try {
    const catalog = JSON.parse(text) as {
      strings?: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }>;
    };
    for (const [key, value] of Object.entries(catalog.strings ?? {})) {
      const english = value.localizations?.en?.stringUnit?.value;
      if (typeof english === "string") map.set(key, english);
    }
  } catch {
    // The localization checker reports malformed catalogs separately.
  }
  return map;
}

function finding(
  rule: Rule,
  file: string,
  source: string,
  offset: number,
  fingerprint: string,
  message: string,
): Finding {
  return { rule, file: relativeFile(file), line: lineAt(source, offset), fingerprint, message };
}

export function findNarration(file: string, source: string, translations = new Map<string, string>()): Finding[] {
  const findings: Finding[] = [];
  if (file.endsWith(".xcstrings")) {
    for (const { value, offset } of collectTranslations(file, source)) {
      const match = NARRATION_PATTERNS.find(([pattern]) => pattern.test(value));
      if (match)
        findings.push(finding("narration", file, source, offset, normalizeCopy(value), `narration: ${match[1]}`));
    }
    return findings;
  }
  const ast = parseSource(file, source);
  const visit = (node: ts.Node) => {
    const copy = candidateCopy(node, translations);
    if (copy) {
      const match = NARRATION_PATTERNS.find(([pattern]) => pattern.test(copy));
      if (match)
        findings.push(
          finding("narration", file, source, node.getStart(ast), normalizeCopy(copy), `narration: ${match[1]}`),
        );
    }
    ts.forEachChild(node, visit);
  };
  visit(ast);
  return findings;
}

function translatedCall(node: ts.Expression, translations: Map<string, string>): string | undefined {
  if (!ts.isCallExpression(node) || !ts.isIdentifier(node.expression)) return undefined;
  if (!/^(?:t|translate|i18n)$/i.test(node.expression.text)) return undefined;
  const key = node.arguments[0];
  return key && (ts.isStringLiteral(key) || ts.isNoSubstitutionTemplateLiteral(key))
    ? translations.get(key.text)
    : undefined;
}

/** Rendered copy in order; null marks content the source cannot prove (`{item.name}`, a component's output). */
type CopyChunk = string | null;

/**
 * The copy an expression child renders. Only values JSX would print count: literals, t() calls, nested JSX and
 * the branches of ?:, && and ||/??. A comparison operand (`kind === "agent"`) or another call's argument is not copy.
 */
function renderedCopy(node: ts.Expression, translations: Map<string, string>, chunks: CopyChunk[]): void {
  if (ts.isParenthesizedExpression(node)) renderedCopy(node.expression, translations, chunks);
  else if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node) || ts.isNumericLiteral(node))
    chunks.push(node.text);
  else if (ts.isTemplateExpression(node)) chunks.push(node.head.text, null);
  else if (ts.isConditionalExpression(node)) {
    renderedCopy(node.whenTrue, translations, chunks);
    renderedCopy(node.whenFalse, translations, chunks);
  } else if (ts.isBinaryExpression(node)) {
    const operator = node.operatorToken.kind;
    if (operator === ts.SyntaxKind.AmpersandAmpersandToken) renderedCopy(node.right, translations, chunks);
    else if (operator === ts.SyntaxKind.BarBarToken || operator === ts.SyntaxKind.QuestionQuestionToken) {
      renderedCopy(node.left, translations, chunks);
      renderedCopy(node.right, translations, chunks);
    } else chunks.push(null);
  } else if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node) || ts.isJsxFragment(node)) {
    jsxChildrenCopy(node, translations, chunks);
  } else if (
    node.kind === ts.SyntaxKind.NullKeyword ||
    node.kind === ts.SyntaxKind.TrueKeyword ||
    node.kind === ts.SyntaxKind.FalseKeyword ||
    (ts.isIdentifier(node) && node.text === "undefined")
  ) {
    // Renders nothing.
  } else chunks.push(translatedCall(node, translations) ?? null);
}

function jsxChildrenCopy(
  node: ts.JsxElement | ts.JsxSelfClosingElement | ts.JsxFragment,
  translations: Map<string, string>,
  chunks: CopyChunk[],
): void {
  if (ts.isJsxSelfClosingElement(node)) {
    // An intrinsic like <img /> renders no copy; a component's output is unknown here.
    if (/^[A-Z]/.test(jsxName(node.tagName))) chunks.push(null);
    return;
  }
  for (const child of node.children) {
    if (ts.isJsxText(child)) chunks.push(child.getText());
    else if (ts.isJsxExpression(child) && child.expression) renderedCopy(child.expression, translations, chunks);
    else if (ts.isJsxElement(child) || ts.isJsxSelfClosingElement(child) || ts.isJsxFragment(child))
      jsxChildrenCopy(child, translations, chunks);
  }
}

function copyChunks(node: ts.Node, translations: Map<string, string>): CopyChunk[] {
  const chunks: CopyChunk[] = [];
  if (ts.isExpression(node)) renderedCopy(node, translations, chunks);
  return chunks;
}

/** The copy a node renders: its JSX children's text, never its attributes (type, className, name). */
function visibleText(node: ts.Node, translations: Map<string, string>): string {
  return normalizeCopy(
    copyChunks(node, translations)
      .filter((chunk) => chunk !== null)
      .join(" "),
  );
}

/** The copy a node certainly starts with, or undefined when unknown content may come first. */
function leadingText(node: ts.Node, translations: Map<string, string>): string | undefined {
  const first = copyChunks(node, translations).find((chunk) => chunk === null || chunk.trim());
  return first === null || first === undefined ? undefined : normalizeCopy(first);
}

const ACTIVATION = ["onClick", "onPointerDown", "onMouseDown", "onDoubleClick"];

/** Pointer activation handlers as source text. Focusability (tabIndex, onKeyDown) alone opens nothing. */
function activationHandlers(element: ts.JsxElement | ts.JsxSelfClosingElement): string[] {
  return ACTIVATION.flatMap((name) => {
    const initializer = jsxAttribute(element, name)?.initializer;
    return initializer ? [initializer.getText()] : [];
  });
}

/**
 * A row that performs the button's action: the button has no activation of its own (its click falls through to
 * the row) or the same handler as the row. A row that only stops propagation does not duplicate the button.
 */
function sameActionRow(
  button: ts.JsxElement | ts.JsxSelfClosingElement,
): ts.JsxElement | ts.JsxSelfClosingElement | undefined {
  const own = activationHandlers(button);
  return ancestors(button).find((ancestor): ancestor is ts.JsxElement | ts.JsxSelfClosingElement => {
    if (!ts.isJsxElement(ancestor) && !ts.isJsxSelfClosingElement(ancestor)) return false;
    const row = activationHandlers(ancestor);
    return row.length > 0 && (own.length === 0 || own.some((handler) => row.includes(handler)));
  });
}

export function findRedundantOpenButtons(
  file: string,
  source: string,
  translations = new Map<string, string>(),
): Finding[] {
  const ast = parseSource(file, source);
  const findings: Finding[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) {
      if (jsxName(openingElement(node).tagName).toLowerCase() === "button") {
        const label = visibleText(node, translations) || attributeText(node, "aria-label") || "";
        if (/^open(?:\s|…|$)/i.test(label)) {
          if (sameActionRow(node)) {
            findings.push(
              finding(
                "redundant-open",
                file,
                source,
                node.getStart(ast),
                normalizeCopy(label),
                `redundant Open button inside a clickable row (${normalizeCopy(label)})`,
              ),
            );
          }
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(ast);
  return findings;
}

function multiSpace(value: string): boolean {
  return /\S {2,}\S/.test(value.replace(/\u00a0/g, " "));
}

export function findMultiSpace(file: string, source: string, translations = new Map<string, string>()): Finding[] {
  const findings: Finding[] = [];
  if (file.endsWith(".xcstrings")) {
    for (const { value, offset } of collectTranslations(file, source)) {
      if (multiSpace(value))
        findings.push(
          finding("multi-space", file, source, offset, normalizeCopy(value), "multiple spaces in inline UI copy"),
        );
    }
    return findings;
  }
  const ast = parseSource(file, source);
  const visit = (node: ts.Node) => {
    const copy = ts.isJsxText(node)
      ? node.getText()
      : ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)
        ? candidateCopy(node, translations)
        : undefined;
    if (copy && multiSpace(copy))
      findings.push(
        finding(
          "multi-space",
          file,
          source,
          node.getStart(ast),
          normalizeCopy(copy),
          "multiple spaces in inline UI copy",
        ),
      );
    ts.forEachChild(node, visit);
  };
  visit(ast);
  return findings;
}

function mapCallback(node: ts.CallExpression): ts.Node | undefined {
  if (!ts.isPropertyAccessExpression(node.expression) || node.expression.name.text !== "map") return undefined;
  const callback = node.arguments[0];
  if (!callback || (!ts.isArrowFunction(callback) && !ts.isFunctionExpression(callback))) return undefined;
  if (!ts.isBlock(callback.body)) return callback.body;
  for (const statement of callback.body.statements) {
    if (ts.isReturnStatement(statement) && statement.expression) return statement.expression;
  }
  return undefined;
}

export function findRepeatedLeadingLabels(
  file: string,
  source: string,
  translations = new Map<string, string>(),
): Finding[] {
  const ast = parseSource(file, source);
  const findings: Finding[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isCallExpression(node)) {
      const row = mapCallback(node);
      if (row) {
        const text = leadingText(row, translations) ?? "";
        const first = /^(\p{L}[\p{L}-]*)\b/u.exec(text)?.[1]?.toLowerCase();
        if (first && TYPE_LABELS.has(first)) {
          findings.push(
            finding(
              "repeated-leading-label",
              file,
              source,
              node.getStart(ast),
              first,
              `mapped rows repeat the type label “${first}”; use the row icon after the list header names the type`,
            ),
          );
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(ast);
  return findings;
}

function className(element: ts.JsxElement | ts.JsxSelfClosingElement): string {
  return attributeText(element, "className") ?? "";
}

function insideAgentMark(node: ts.Node): boolean {
  return ancestors(node).some((ancestor) => {
    if (!ts.isJsxElement(ancestor) && !ts.isJsxSelfClosingElement(ancestor)) return false;
    return jsxName(openingElement(ancestor).tagName) === "AgentMark";
  });
}

export function findHardCodedAgentIcons(file: string, source: string): Finding[] {
  const ast = parseSource(file, source);
  const findings: Finding[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) {
      if (
        jsxName(openingElement(node).tagName) === "Icon" &&
        HARNESS_ICON.test(attributeText(node, "name") ?? "") &&
        !insideAgentMark(node)
      ) {
        const row = ancestors(node).find(
          (ancestor): ancestor is ts.JsxElement | ts.JsxSelfClosingElement =>
            (ts.isJsxElement(ancestor) || ts.isJsxSelfClosingElement(ancestor)) && ROW_CLASS.test(className(ancestor)),
        );
        if (row) {
          const icon = attributeText(node, "name") ?? "agent";
          findings.push(
            finding(
              "hard-coded-agent-icon",
              file,
              source,
              node.getStart(ast),
              `${className(row)}|${icon}`,
              `agent/session row uses ${icon}; render the harness icon component with a stable item colour`,
            ),
          );
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(ast);
  return findings;
}

function cssRowGroups(file: string, source: string): Finding[] {
  const groups = new Map<string, Array<{ weight: string; offset: number }>>();
  const block = /([^{}]+)\{([^{}]*)\}/g;
  for (const match of source.matchAll(block)) {
    const body = match[2] ?? "";
    const weight = /(?:^|;)\s*font-weight\s*:\s*([^;}]*)/i.exec(body)?.[1]?.trim();
    if (!weight || /^(?:inherit|normal)$/i.test(weight)) continue;
    const classes = [...(match[1] ?? "").matchAll(/\.([A-Za-z_][\w-]*)/g)].map((item) => item[1]!);
    const candidates = classes
      .map((name) => (name.includes("__") ? name.split("__", 1)[0]! : ROW_CLASS.test(name) ? name : undefined))
      .filter((name): name is string => Boolean(name));
    for (const group of new Set(candidates)) {
      const list = groups.get(group) ?? [];
      list.push({ weight, offset: (match.index ?? 0) + match[0].indexOf("font-weight") });
      groups.set(group, list);
    }
  }
  const findings: Finding[] = [];
  for (const [group, entries] of groups) {
    const weights = [...new Set(entries.map((entry) => entry.weight))];
    if (weights.length < 2) continue;
    findings.push(
      finding(
        "mixed-row-weight",
        file,
        source,
        Math.min(...entries.map((entry) => entry.offset)),
        `${group}|${weights.sort().join(",")}`,
        `row kind ${group} declares mixed font weights (${weights.join(", ")})`,
      ),
    );
  }
  return findings;
}

export function findMixedRowWeights(file: string, source: string): Finding[] {
  return file.endsWith(".css") ? cssRowGroups(file, source) : [];
}

export function scanFile(file: string, source: string, translations: Map<string, string>): Finding[] {
  if (file.endsWith(".css")) return findMixedRowWeights(file, source);
  return [
    ...findNarration(file, source, translations),
    ...findRedundantOpenButtons(file, source, translations),
    ...findMultiSpace(file, source, translations),
    ...findRepeatedLeadingLabels(file, source, translations),
    ...findHardCodedAgentIcons(file, source),
  ];
}

export function loadAllowlist(file = ALLOWLIST): AllowlistEntry[] {
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => JSON.parse(line) as AllowlistEntry);
}

function allowlistKey(entry: Pick<AllowlistEntry, "rule" | "file" | "fingerprint">): string {
  return `${entry.rule}\0${entry.file}\0${entry.fingerprint}`;
}

export interface ScanResult {
  findings: Finding[];
  newFindings: Finding[];
  staleAllowlist: AllowlistEntry[];
}

export function scanTree(root = SOURCE_ROOT, allowlist = loadAllowlist()): ScanResult {
  const files = sourceFiles(root);
  const translations = new Map<string, string>();
  for (const file of files) {
    for (const [key, value] of translationMap(file, readFileSync(file, "utf8"))) translations.set(key, value);
  }
  const findings = files.flatMap((file) => {
    const source = readFileSync(file, "utf8");
    return scanFile(file, source, translations);
  });
  return classifyFindings(findings, allowlist);
}

/** Each allowlist entry excuses one finding: a second finding with the same rule, file and
 * fingerprint is new, and an entry no finding used is stale. */
export function classifyFindings(findings: Finding[], allowlist: AllowlistEntry[]): ScanResult {
  const remaining = new Map<string, number>();
  for (const entry of allowlist) remaining.set(allowlistKey(entry), (remaining.get(allowlistKey(entry)) ?? 0) + 1);
  const newFindings = findings.filter((item) => {
    const key = allowlistKey(item);
    const left = remaining.get(key) ?? 0;
    if (left === 0) return true;
    remaining.set(key, left - 1);
    return false;
  });
  const staleAllowlist = allowlist.filter((entry) => {
    const key = allowlistKey(entry);
    const left = remaining.get(key) ?? 0;
    if (left === 0) return false;
    remaining.set(key, left - 1);
    return true;
  });
  return { findings, newFindings, staleAllowlist };
}

function main(): void {
  const result = scanTree();
  for (const item of result.newFindings) {
    console.warn(
      `::warning file=webviews/${item.file},line=${item.line},title=UI review ${item.rule}::${item.message}`,
    );
  }
  for (const item of result.staleAllowlist) {
    console.warn(
      `::warning file=webviews/${item.file},title=stale UI review allowlist entry::${item.rule}: ${item.fingerprint}`,
    );
  }
  const counts = new Map<Rule, number>();
  for (const item of result.findings) counts.set(item.rule, (counts.get(item.rule) ?? 0) + 1);
  console.log(
    `ui-review: scanned ${result.findings.length} finding(s); ${result.newFindings.length} new; ${result.staleAllowlist.length} stale baseline`,
  );
  for (const [rule, count] of counts) console.log(`  ${rule}: ${count}`);
  // New findings warn and never fail; an exception from scanTree() is a broken checker and fails.
}

if (import.meta.main) main();
