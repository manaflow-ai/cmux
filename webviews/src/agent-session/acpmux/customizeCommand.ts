/// `/customize …` in a chat: customize cmux by asking (cmuxterm-hq
/// `plans/cmux-next/customize-by-asking/DESIGN.md`).
///
/// The chat's own agent does the work with `cmux customize`, the same verbs the CLI and the
/// `customize_*` MCP tools run, so this file only says what the agent is asked. A wish opens (or
/// goes on with) the draft and the agent edits live; a verb (`/customize apply`) runs that verb.
/// The text is short on purpose: it is what the person's own message shows in the transcript.

/// The verbs a person types after `/customize`, with what may follow each.
const VERBS: Readonly<Record<string, "none" | "number" | "name" | "note">> = {
  status: "none",
  diff: "none",
  apply: "note",
  discard: "none",
  rollback: "number",
  undo: "number",
  generations: "none",
  history: "none",
  profiles: "none",
  show: "number",
  save: "name",
  use: "name",
};

/// One shell word: single quotes, with a quote inside closed and reopened.
export function shellWord(text: string): string {
  return `'${text.replaceAll("'", "'\\''")}'`;
}

/// The `cmux customize` command a typed verb names, or undefined when `args` is a wish.
export function customizeVerb(args: string): string | undefined {
  const words = args.trim().split(/\s+/).filter(Boolean);
  const [verb, ...rest] = words;
  if (!verb) return "cmux customize status";
  const takes = VERBS[verb.toLowerCase()];
  if (!takes) return undefined;
  const name = verb.toLowerCase() === "undo" ? "rollback" : verb.toLowerCase() === "history" ? "generations" : verb.toLowerCase();
  if (takes === "none") return rest.length === 0 ? `cmux customize ${name}` : undefined;
  if (takes === "number") {
    if (rest.length === 0 && name === "rollback") return "cmux customize rollback";
    return rest.length === 1 && /^#?\d+$/.test(rest[0]!) ? `cmux customize ${name} ${rest[0]!.replace("#", "")}` : undefined;
  }
  if (takes === "name") {
    // A profile name; anything else after `save` or `use` reads as a wish ("use a darker theme").
    if (rest.length === 0 || !/^[a-z0-9][a-z0-9_-]*$/.test(rest[0]!)) return undefined;
    if (name === "use") return rest.length === 1 ? `cmux customize use ${rest[0]}` : undefined;
    const note = rest.slice(1).join(" ");
    return `cmux customize save ${rest[0]}${note ? ` ${shellWord(note)}` : ""}`;
  }
  // `apply` alone or with a short label; "apply a night theme" is a wish, as it is in the CLI.
  return rest.length === 0 ? "cmux customize apply" : undefined;
}

/// The prompt a typed `/customize ARGS` sends to the chat's agent.
export function customizePrompt(args: string): string {
  const verb = customizeVerb(args);
  if (verb) return `Run \`${verb}\` and tell me what it says, in a sentence or two.`;
  const wish = args.trim();
  return [
    `Customize cmux: ${wish}`,
    "",
    `Run \`cmux customize brief -- ${shellWord(wish)}\` and do what it prints. I am watching the window, and every file you save shows there at once as a preview. Do not apply or discard it; I will.`,
  ].join("\n");
}

/// A whole typed message that is `/customize …`, as the prompt it sends; undefined for any other.
export function customizeMessage(text: string): string | undefined {
  const match = /^\/customize(?:\s+([\s\S]*))?$/i.exec(text.trim());
  return match ? customizePrompt(match[1] ?? "") : undefined;
}
