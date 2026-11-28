/**
 * `uses:` references, repository file access, and expression references found
 * in parsed YAML values.
 */

import { hasExpression, parseCondition, parseTemplate } from "../expr/evaluate.ts";
import { type ContextName, contextReferences, type Expr } from "../expr/parser.ts";
import { isArray, isObject, type Value } from "../expr/value.ts";
import { type Action, parseAction } from "../workflow/model.ts";

/** Read access to the repository tree at the run's exact SHA. */
export interface RepoFiles {
  read(path: string): string | undefined;
}

export type UsesRef =
  | { readonly kind: "local"; readonly path: string }
  | { readonly kind: "docker"; readonly image: string }
  | {
      readonly kind: "remote";
      readonly owner: string;
      readonly repo: string;
      readonly path: string;
      readonly ref: string;
      /** owner/repo for an action, owner/repo/path for an action in a subdirectory. */
      readonly name: string;
    };

const FULL_SHA = /^[0-9a-f]{40}$/;

export const parseUses = (uses: string): UsesRef => {
  if (uses.startsWith("./")) return { kind: "local", path: uses.slice(2).replace(/\/+$/, "") };
  if (uses.startsWith("docker://")) return { kind: "docker", image: uses.slice("docker://".length) };
  const at = uses.lastIndexOf("@");
  const target = at === -1 ? uses : uses.slice(0, at);
  const ref = at === -1 ? "" : uses.slice(at + 1);
  const [owner = "", repo = "", ...rest] = target.split("/");
  return { kind: "remote", owner, repo, path: rest.join("/"), ref, name: target };
};

export const isPinned = (ref: UsesRef): boolean => ref.kind !== "remote" || FULL_SHA.test(ref.ref);

/** Loads `action.yml` (or `action.yaml`) of a local action directory. */
export const loadLocalAction = (files: RepoFiles, directory: string): Action | undefined => {
  for (const name of ["action.yml", "action.yaml"]) {
    const path = `${directory}/${name}`;
    const text = files.read(path);
    if (text !== undefined) return parseAction(text, path);
  }
  return undefined;
};

/** Every string inside a parsed YAML value (keys excluded). */
export function* strings(value: Value): Generator<string> {
  if (typeof value === "string") yield value;
  else if (isArray(value)) for (const item of value) yield* strings(item);
  else if (isObject(value)) for (const item of Object.values(value)) yield* strings(item);
}

/** Parsed expressions of every `${{ }}` inside a value. Throws on a malformed expression. */
export const templateExpressions = (value: Value): Expr[] => {
  const found: Expr[] = [];
  for (const text of strings(value)) {
    if (!hasExpression(text)) continue;
    for (const part of parseTemplate(text)) if ("expr" in part) found.push(part.expr);
  }
  return found;
};

/** Parsed `if:` conditions plus every `${{ }}` in the other fields of a job or step. */
export const expressionsOf = (raw: Value): Expr[] => {
  const found: Expr[] = [];
  if (isObject(raw)) {
    for (const [key, item] of Object.entries(raw)) {
      if (key === "if" && (typeof item === "string" || typeof item === "boolean")) found.push(parseCondition(String(item)));
      else if (key === "steps" && isArray(item)) for (const step of item) found.push(...expressionsOf(step));
      else found.push(...templateExpressions(item));
    }
    return found;
  }
  return templateExpressions(raw);
};

export const referencedProperties = (exprs: readonly Expr[], context: ContextName): Set<string> => {
  const out = new Set<string>();
  for (const expr of exprs) {
    for (const reference of contextReferences(expr)) {
      if (reference.context === context && reference.property !== null) out.add(reference.property);
    }
  }
  return out;
};

export const referencesContext = (value: Value, context: ContextName): boolean =>
  templateExpressions(value).some((expr) => contextReferences(expr).some((reference) => reference.context === context));
