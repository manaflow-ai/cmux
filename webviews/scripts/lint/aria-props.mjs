// jsx-a11y's role-supports-aria-props with ARIA 1.3's aria-description as a global attribute.
// Oxlint's built-in rule has no options, and its role table (like aria-query 5.3.0's) predates ARIA 1.3, where
// aria-description is global: every role supports it. c0ecbb88 replaced visible-text tooltips with it, and the
// built-in rule flagged 29 of those props. This rule is the same check (an aria-* prop the element's explicit or
// implicit role does not support) on aria-query's tables, plus aria-description everywhere; every other attribute
// is judged as before (test/aria-props-lint.test.ts).
import { aria, roles } from "aria-query";

const ARIA_1_3_GLOBALS = new Set(["aria-description"]);

function attribute(node, name) {
  return node.attributes.find(
    (attr) =>
      attr.type === "JSXAttribute" && attr.name.type === "JSXIdentifier" && attr.name.name.toLowerCase() === name,
  );
}

// A literal value, as jsx-a11y reads it: "x", {"x"} or {`x`}; anything computed is undefined.
function literal(attr) {
  if (!attr) return undefined;
  const value = attr.value;
  if (value === null) return true;
  if (value.type === "Literal") return value.value;
  if (value.type !== "JSXExpressionContainer") return undefined;
  const expression = value.expression;
  if (expression.type === "Literal") return expression.value;
  if (expression.type === "TemplateLiteral" && expression.expressions.length === 0)
    return expression.quasis[0].value.cooked;
  return undefined;
}

const has = (node, name) => attribute(node, name) !== undefined;
const lower = (value) => (typeof value === "string" ? value.toLowerCase() : "");

// eslint-plugin-jsx-a11y's implicit roles (src/util/implicitRoles).
const IMPLICIT = {
  a: (node) => (has(node, "href") ? "link" : ""),
  area: (node) => (has(node, "href") ? "link" : ""),
  article: () => "article",
  aside: () => "complementary",
  body: () => "document",
  button: () => "button",
  datalist: () => "listbox",
  details: () => "group",
  dialog: () => "dialog",
  form: () => "form",
  h1: () => "heading",
  h2: () => "heading",
  h3: () => "heading",
  h4: () => "heading",
  h5: () => "heading",
  h6: () => "heading",
  hr: () => "separator",
  img: (node) => (literal(attribute(node, "alt")) === "" ? "" : "img"),
  input: (node) => {
    const type = lower(literal(attribute(node, "type")));
    if (["button", "image", "reset", "submit"].includes(type)) return "button";
    if (type === "checkbox") return "checkbox";
    if (type === "radio") return "radio";
    if (type === "range") return "slider";
    if (type === "number") return "spinbutton";
    if (type === "search") return "searchbox";
    return "textbox";
  },
  li: () => "listitem",
  link: (node) => (has(node, "href") ? "link" : ""),
  menu: (node) => (lower(literal(attribute(node, "type"))) === "toolbar" ? "toolbar" : ""),
  menuitem: (node) =>
    ({ command: "menuitem", checkbox: "menuitemcheckbox", radio: "menuitemradio" })[
      lower(literal(attribute(node, "type")))
    ] ?? "",
  meter: () => "progressbar",
  nav: () => "navigation",
  ol: () => "list",
  option: () => "option",
  output: () => "status",
  progress: () => "progressbar",
  section: () => "region",
  select: () => "listbox",
  tbody: () => "rowgroup",
  textarea: () => "textbox",
  tfoot: () => "rowgroup",
  thead: () => "rowgroup",
  ul: () => "list",
};

export const roleSupportsAriaProps = {
  meta: {
    type: "problem",
    schema: [],
    messages: {
      explicit: "The attribute `{{name}}` is not supported by the role `{{role}}`.",
      implicit:
        "The attribute `{{name}}` is not supported by the role `{{role}}`. This role is implicit on the element `{{tag}}`.",
    },
  },
  create(context) {
    return {
      JSXOpeningElement(node) {
        // DOM elements only: a component's props are its own.
        if (node.name.type !== "JSXIdentifier" || !/^[a-z]/.test(node.name.name)) return;
        const tag = node.name.name;
        const roleAttr = attribute(node, "role");
        const explicit = literal(roleAttr);
        // A computed role (role={multi ? "checkbox" : "radio"}) is not judged, as the built-in rule does not.
        if (roleAttr && typeof explicit !== "string") return;
        const role =
          typeof explicit === "string" ? explicit.trim().split(/\s+/)[0].toLowerCase() : IMPLICIT[tag]?.(node) || "";
        // No role (or a computed one): the element takes the global aria-* set, as the built-in rule assumes.
        const definition = role && roles.get(role);
        if (!definition) return;
        const permitted = new Set(Object.keys(definition.props));
        for (const attr of node.attributes) {
          if (attr.type !== "JSXAttribute" || attr.name.type !== "JSXIdentifier") continue;
          const name = attr.name.name.toLowerCase();
          if (!name.startsWith("aria-") || !aria.has(name) || permitted.has(name) || ARIA_1_3_GLOBALS.has(name))
            continue;
          context.report({
            node: attr,
            messageId: typeof explicit === "string" ? "explicit" : "implicit",
            data: { name, role, tag },
          });
        }
      },
    };
  },
};

export default {
  meta: { name: "cmux-a11y" },
  rules: { "role-supports-aria-props": roleSupportsAriaProps },
};
