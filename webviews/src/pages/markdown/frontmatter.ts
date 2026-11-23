// Front matter as a table (the rich view's metadata block): the YAML between the `---` fences read
// into key and value rows. Only a view: the raw block keeps the text verbatim (sourceMap.ts), so a
// save writes it back byte for byte. A small reader, not a YAML parser: top-level `key: value`
// lines, with a nested map, a list or a block scalar under a key shown compactly on one row.

export interface FrontmatterRow {
  key: string;
  /** A scalar's text, or a list's items (an inline `[a, b]` or `- a` lines). */
  value: string | string[];
}

const KEY_LINE = /^([^\s#:][^:]*?)\s*:(?:\s+(.*))?$/;

/** The rows of front matter `text` (without its fences); null when it holds no `key: value` line. */
export function frontmatterRows(text: string): FrontmatterRow[] | null {
  const rows: FrontmatterRow[] = [];
  let current: { key: string; inline: string; nested: string[] } | null = null;
  const finish = () => {
    if (current) rows.push({ key: current.key, value: rowValue(current.inline, current.nested) });
    current = null;
  };
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const top = /^\S/.test(line) ? KEY_LINE.exec(line) : null;
    if (top) {
      finish();
      current = { key: unquote(top[1]!), inline: (top[2] ?? "").trim(), nested: [] };
    } else if (current) current.nested.push(line);
  }
  finish();
  return rows.length ? rows : null;
}

function rowValue(inline: string, nested: string[]): string | string[] {
  const value = stripComment(inline);
  // A block scalar (`|`, `>`): its lines, folded to one.
  if (/^[|>][+-]?\d*$/.test(value)) return nested.map((line) => line.trim()).join(" ");
  if (value.startsWith("[") && value.endsWith("]")) return splitFlow(value.slice(1, -1)).map(unquote);
  if (value.startsWith("{") && value.endsWith("}")) return splitFlow(value.slice(1, -1)).join(", ");
  if (value) return unquote(value);
  if (!nested.length) return "";
  const lines = nested.map((line) => line.trim());
  // A block list: one item per `- ` line at the list's indent (deeper lines join their item).
  if (lines[0]!.startsWith("- ") || lines[0] === "-") {
    const indent = indentOf(nested[0]!);
    const items: string[] = [];
    for (const [index, line] of nested.entries()) {
      if (indentOf(line) === indent && /^\s*-(\s|$)/.test(line))
        items.push(unquote(stripComment(lines[index]!.slice(1).trim())));
      else if (items.length) items[items.length - 1] = `${items[items.length - 1]} ${lines[index]}`.trim();
    }
    return items;
  }
  // A nested map: `key: value` pairs on one row.
  return lines.map(stripComment).filter(Boolean).join("; ");
}

/** The items of a flow collection's inside, split at top-level commas. */
function splitFlow(inside: string): string[] {
  const items: string[] = [];
  let depth = 0;
  let quote = "";
  let start = 0;
  for (let index = 0; index < inside.length; index++) {
    const char = inside[index]!;
    if (quote) {
      if (char === quote) quote = "";
    } else if (char === '"' || char === "'") quote = char;
    else if (char === "[" || char === "{") depth++;
    else if (char === "]" || char === "}") depth--;
    else if (char === "," && depth === 0) {
      items.push(inside.slice(start, index).trim());
      start = index + 1;
    }
  }
  items.push(inside.slice(start).trim());
  return items.filter(Boolean);
}

function stripComment(value: string): string {
  if (value.startsWith('"') || value.startsWith("'")) return value;
  return value.replace(/\s+#.*$/, "").trim();
}

function unquote(value: string): string {
  const text = value.trim();
  if (text.length >= 2 && (text[0] === '"' || text[0] === "'") && text.at(-1) === text[0]) return text.slice(1, -1);
  return text;
}

function indentOf(line: string): number {
  return line.length - line.trimStart().length;
}

/** The table for `rows`: a key column and a value column; a list's items as small chips. */
export function frontmatterTable(rows: readonly FrontmatterRow[]): HTMLTableElement {
  const table = document.createElement("table");
  table.className = "md-frontmatter-table";
  const body = table.createTBody();
  for (const row of rows) {
    const tr = body.insertRow();
    const key = document.createElement("th");
    key.scope = "row";
    key.textContent = row.key;
    const value = tr.insertCell();
    tr.prepend(key);
    if (Array.isArray(row.value)) {
      for (const item of row.value) {
        const chip = document.createElement("span");
        chip.className = "md-frontmatter-item";
        chip.textContent = item;
        value.append(chip);
      }
    } else value.textContent = row.value;
  }
  return table;
}
