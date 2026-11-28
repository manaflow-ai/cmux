// Code colors from the terminal theme's ANSI palette, as Ghostty colors a program's output: one
// map from Shiki scopes to palette slots for the agent chat (acpmux/diffTheme.ts), the diff viewer
// and the Markdown page (pierre-options.ts `shikiThemeFromGhostty`). Each rule's color is a CSS
// variable, so a theme change recolors code in place: the chat reads the pane's `--agent-ansi-N`
// (AgentPaneTheme.swift lifts them), the pages read `--cmux-syntax-{light,dark}-<role>`, which
// appearance.ts sets from the terminal theme with every host theme change.
import { defaultSyntaxPalettes, syntaxPaletteColor } from "./syntax-colors";

type FontStyle = "bold" | "italic";

/** A token role: its scopes, the palette slots it takes (the first the theme names), its style. */
type SyntaxRole = { scopes: string[]; slots: number[]; fontStyle?: FontStyle };

/** Every role; `variable` has no slots and reads as plain text. */
export const SYNTAX_ROLES = {
  comment: { scopes: ["comment", "punctuation.definition.comment", "string.comment"], slots: [8], fontStyle: "italic" },
  string: { scopes: ["string", "string.quoted", "constant.other.symbol", "string.regexp"], slots: [2] },
  constant: {
    scopes: [
      "constant.numeric",
      "constant.language",
      "constant.character",
      "support.constant",
      "variable.other.enummember",
    ],
    slots: [3],
  },
  keyword: {
    scopes: ["keyword", "storage", "storage.type", "storage.modifier", "keyword.operator.new", "keyword.control"],
    slots: [5],
  },
  function: {
    scopes: ["entity.name.function", "support.function", "meta.function-call entity.name.function"],
    slots: [4],
  },
  type: {
    scopes: ["entity.name.type", "entity.name.class", "entity.other.inherited-class", "support.type", "support.class"],
    slots: [6],
  },
  tag: { scopes: ["entity.name.tag", "meta.tag.sgml", "entity.name.section"], slots: [1] },
  attribute: { scopes: ["entity.other.attribute-name"], slots: [3] },
  heading: {
    scopes: ["markup.heading", "punctuation.definition.heading", "entity.name.section.markdown"],
    slots: [12, 4],
    fontStyle: "bold",
  },
  bold: { scopes: ["markup.bold", "punctuation.definition.bold"], slots: [11, 3], fontStyle: "bold" },
  italic: { scopes: ["markup.italic", "punctuation.definition.italic"], slots: [13, 5], fontStyle: "italic" },
  raw: {
    scopes: [
      "markup.inline.raw",
      "markup.inline.raw.string.markdown",
      "markup.raw",
      "markup.fenced_code",
      "markup.raw.block",
    ],
    slots: [10, 2],
  },
  link: {
    scopes: ["markup.underline.link", "string.other.link", "string.other.link.title.markdown", "markup.link"],
    slots: [14, 6],
  },
  quote: { scopes: ["markup.quote", "punctuation.definition.quote"], slots: [8], fontStyle: "italic" },
  // The bullet only: `markup.list` spans the whole item, which would color every list line.
  list: { scopes: ["punctuation.definition.list", "markup.table"], slots: [9, 1] },
  inserted: { scopes: ["markup.inserted", "punctuation.definition.inserted"], slots: [2] },
  deleted: { scopes: ["markup.deleted", "punctuation.definition.deleted"], slots: [1] },
  variable: { scopes: ["variable", "variable.other", "variable.parameter", "meta.definition.variable"], slots: [] },
  invalid: { scopes: ["invalid", "message.error"], slots: [9, 1] },
} satisfies Record<string, SyntaxRole>;

export type SyntaxRoleName = keyof typeof SYNTAX_ROLES;
type TokenRule = { scope?: string[]; settings: { foreground: string; background?: string; fontStyle?: FontStyle } };

/** Shiki token rules, the plain-text rule first, with each role's color from `color`. */
export function syntaxTokenRules(
  plain: { foreground: string; background?: string },
  color: (role: SyntaxRoleName, spec: SyntaxRole) => string,
): TokenRule[] {
  const roles = Object.entries(SYNTAX_ROLES) as Array<[SyntaxRoleName, SyntaxRole]>;
  return [
    { settings: plain },
    ...roles.map(([role, spec]) => ({
      scope: spec.scopes,
      settings: { foreground: color(role, spec), ...(spec.fontStyle ? { fontStyle: spec.fontStyle } : {}) },
    })),
  ];
}

/** The variable a page's code reads for `role` in a scheme (appearance.ts sets it). */
export function pageSyntaxVariable(type: "light" | "dark", role: SyntaxRoleName): string {
  return `--cmux-syntax-${type}-${role}`;
}

/**
 * Each role's color for a terminal theme: the first palette slot it names (the default palette
 * fills a slot the theme leaves out), blended toward the foreground just enough to read on the
 * background (syntax-colors.ts); `variable` is the foreground.
 */
export function syntaxRoleColors(
  palette: Record<string, string | undefined>,
  type: "light" | "dark",
  background: string,
  foreground: string,
): Record<SyntaxRoleName, string> {
  const roles = Object.entries(SYNTAX_ROLES) as Array<[SyntaxRoleName, SyntaxRole]>;
  return Object.fromEntries(
    roles.map(([role, spec]) => [
      role,
      spec.slots.length ? syntaxPaletteColor(palette, spec.slots, type, background, foreground) : foreground,
    ]),
  ) as Record<SyntaxRoleName, string>;
}

/** The agent pane's color for a role: its lifted ANSI slot, the default palette behind it. */
export function agentSyntaxColor(spec: SyntaxRole, type: "light" | "dark", foreground: string): string {
  const slot = spec.slots[0];
  if (slot == null) return foreground;
  return `var(--agent-ansi-${slot}, ${defaultSyntaxPalettes[type][String(slot)]})`;
}
