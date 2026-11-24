import type { AcpmuxActivity, AcpmuxFileDiff, AcpmuxLocation, ClaimCheck } from "../model";

export const objectValue = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
export const stringValue = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;

/** The session to attach after connect: the selected one, else the most recent unless the pane is a new chat. */
export function initialSession(
  selected: string | undefined,
  sessions: { sessionId: string }[],
  newSession?: boolean,
): string | undefined {
  if (selected) return selected;
  return newSession ? undefined : sessions[0]?.sessionId;
}

/// The file changes in a tool call's content (ACP `diff` items), placed by the call's locations.
export function toolDiffs(content: any, locations: any): AcpmuxFileDiff[] | undefined {
  if (!Array.isArray(content)) return undefined;
  const lines = new Map<string, number>();
  for (const location of Array.isArray(locations) ? locations : [])
    if (
      typeof location?.path === "string" &&
      Number.isInteger(location.line) &&
      location.line > 0 &&
      !lines.has(location.path)
    )
      lines.set(location.path, location.line);
  const diffs = content
    .filter((item: any) => item?.type === "diff" && typeof item.path === "string" && typeof item.newText === "string")
    .map((item: any): AcpmuxFileDiff => ({
      path: item.path,
      oldText: typeof item.oldText === "string" ? item.oldText : undefined,
      newText: item.newText,
      line: lines.get(item.path),
      ...(item.fragment === true || item._meta?.acpmux?.fragment === true ? { fragment: true as const } : {}),
      ...canonicalOf(item),
    }));
  return diffs.length ? diffs : undefined;
}

/// The canonical path acpmux recorded beside an item's path (hub/tool_paths.rs), as `canonical`:
/// a `diff` item's or location's `_meta.acpmux.canonicalPath`, or a diff this page placed again.
/// Composed (NFC), as every canonical path the page compares is (turnCheckpoint.ts `checkpointFiles`).
function canonicalOf(item: any): { canonical?: string } {
  const canonical = item?._meta?.acpmux?.canonicalPath ?? item?.canonical;
  return typeof canonical === "string" && canonical ? { canonical: canonical.normalize("NFC") } : {};
}

/// A call's locations with their canonical paths read (`canonicalOf`).
function readLocations(locations: any): AcpmuxLocation[] | undefined {
  if (!Array.isArray(locations)) return undefined;
  return locations.map((location: any) =>
    location && typeof location === "object" ? { ...location, ...canonicalOf(location) } : location,
  );
}

/// The input's file and the canonical path acpmux recorded for it on the update (`_meta.acpmux`).
function inputPath(update: any): { path: string; canonical: string } | undefined {
  const path = update.rawInput?.file_path;
  const { canonical } = canonicalOf(update);
  return typeof path === "string" && canonical ? { path, canonical } : undefined;
}

/// Claude Code's result for a Write that made a new file ("File created successfully at: …"). An
/// overwrite says the file was updated, and its old text is not in the call.
const CREATED_RESULT = /^\s*File created successfully at\b/;

/// An edit call's change read from its own input, for a call whose content carries no `diff` item:
/// Claude Code's Edit (`old_string`, `new_string`), MultiEdit (`edits`), and Write (`file_path`,
/// `content`) once its `result` says it created the file; a Write over a file has no old text to
/// diff against, so it stays a path without counts. Each is marked `fragment` (the page never saw the
/// file around it, so Undo, turnChanges/model.ts `fileUndo`, never writes a file back from these)
/// and `fromInput` (a later input replaces them).
export function inputDiffs(rawInput: any, result?: string, canonical?: string): AcpmuxFileDiff[] | undefined {
  const path = rawInput?.file_path;
  if (typeof path !== "string" || !path) return undefined;
  const mark = {
    fragment: true as const,
    fromInput: true as const,
    ...(canonical ? { canonical } : {}),
  };
  if (typeof rawInput.content === "string")
    return result !== undefined && CREATED_RESULT.test(result)
      ? [{ path, newText: rawInput.content, ...mark }]
      : undefined;
  const edits: any[] = Array.isArray(rawInput.edits) ? rawInput.edits : [rawInput];
  const diffs = edits
    .filter((edit) => typeof edit?.old_string === "string" && typeof edit.new_string === "string")
    .map((edit): AcpmuxFileDiff => ({
      path,
      oldText: edit.old_string,
      newText: edit.new_string,
      ...mark,
    }));
  return diffs.length ? diffs : undefined;
}

/// The input an earlier event of a call carried, kept as its `inputSummary` JSON.
function storedInput(summary: string | undefined): unknown {
  if (!summary) return undefined;
  try {
    return JSON.parse(summary);
  } catch {
    return undefined;
  }
}

/// Diffs placed again by an update that brings only locations; diffs read from the input stay marked.
function placeDiffs(diffs: AcpmuxFileDiff[] | undefined, locations: any): AcpmuxFileDiff[] | undefined {
  if (!diffs || !Array.isArray(locations)) return diffs;
  const placed = toolDiffs(
    diffs.map((diff) => ({ type: "diff", ...diff })),
    locations,
  );
  return (
    placed?.map((diff, index) => (diffs[index]?.fromInput ? { ...diff, fromInput: true as const } : diff)) ?? diffs
  );
}

/// A tool call folded with an update to it. ACP updates carry only the fields that changed;
/// content, when present, replaces the call's content. `at` is the event's time: the call
/// starts at its first event and ends at the first that reports it completed or failed.
export function mergeToolItem(
  previous: AcpmuxActivity | undefined,
  update: any,
  callId: string,
  output: string,
  at?: number,
): AcpmuxActivity {
  const before = previous?.tool;
  const provenance =
    typeof update._meta?.claude?.tool === "string" || typeof update._meta?.claudeCode?.toolName === "string"
      ? {
          ...(typeof update._meta?.claude?.tool === "string" ? { claudeTool: update._meta.claude.tool } : {}),
          ...(typeof update._meta?.claudeCode?.toolName === "string"
            ? { claudeCodeToolName: update._meta.claudeCode.toolName }
            : {}),
        }
      : before?.provenance;
  const title = update.title ?? update.name;
  const status = String(update.status ?? before?.status ?? "in_progress");
  const ended = status === "completed" || status === "failed";
  const kind = update.kind ?? before?.kind;
  const locations = readLocations(update.locations) ?? before?.locations;
  // ACP sends an empty object when an update changes status or output without changing the
  // call's input. Keep the input from the initial call so a draft command never regresses to
  // the blank/Thinking state after that update.
  const hasRawInput =
    update.rawInput !== undefined &&
    update.rawInput !== null &&
    !(objectValue(update.rawInput) && Object.keys(update.rawInput).length === 0);
  // The input's file, from the update that carries the input.
  const input = hasRawInput ? inputPath(update) : before?.inputPath;
  const placed =
    update.content === undefined ? placeDiffs(before?.diffs, update.locations) : toolDiffs(update.content, locations);
  // An edit whose content names no `diff` (Claude Code's Edit, whose result is plain text) still
  // changed its file: its input has the change, read again from the latest input. A failed one
  // changed nothing. A `diff` in the content always wins over the input.
  let diffs = placed;
  if (kind === "edit" && (!placed || placed.every((diff) => diff.fromInput))) {
    const result = output || textFromContent(update.content) || before?.output;
    diffs =
      status === "failed"
        ? undefined
        : (inputDiffs(update.rawInput ?? storedInput(before?.inputSummary), result, input?.canonical) ?? placed);
  }
  return {
    kind: "tool",
    text: String(title ?? previous?.text ?? callId),
    tool: {
      id: callId,
      title: String(update.title ?? update.name ?? before?.title ?? callId),
      kind,
      status,
      inputSummary: hasRawInput ? JSON.stringify(update.rawInput) : before?.inputSummary,
      output:
        output ||
        formattedOutput(update.rawOutput) ||
        terminalOutput(update, before?.output) ||
        (update.content === undefined ? before?.output : undefined),
      command: shellCommand(update.rawInput) ?? before?.command,
      description: callDescription(update.rawInput) ?? before?.description,
      exitCode: exitCode(update) ?? before?.exitCode,
      startedAt: before?.startedAt ?? at,
      endedAt: before?.endedAt ?? (ended ? at : undefined),
      // A shell that went to the background stays there as its call's result comes in.
      ...(before?.background ? { background: before.background } : {}),
      // An approval stays on its call as the call's result comes in.
      ...(before?.approved ? { approved: true as const } : {}),
      // What a background task's end left on it (`attachReaction`) stays as later updates come in.
      ...(before?.reaction ? { reaction: before.reaction } : {}),
      locations,
      ...(input ? { inputPath: input } : {}),
      images: update.content === undefined ? before?.images : imagesFromContent(update.content),
      diffs,
      ...(provenance ? { provenance } : {}),
    },
  };
}

/// What a call says it does, in a few words: Claude Code's Bash `description` ("Run the web
/// tests"), which a command row reads instead of its raw command line.
export function callDescription(rawInput: any): string | undefined {
  const description = rawInput?.description;
  return typeof description === "string" && description.trim() ? description.trim() : undefined;
}

/// The command line a shell call ran, from `rawInput.command`: a string, or an argv array. An
/// argv that runs a script through a shell (`zsh -lc "cd x && bun test"`) shows the script;
/// otherwise a part with spaces or quotes is single-quoted, so the line reads as typed.
export function shellCommand(rawInput: any): string | undefined {
  const command = rawInput?.command;
  if (typeof command === "string") return command;
  if (!Array.isArray(command) || !command.every((part) => typeof part === "string") || !command.length)
    return undefined;
  const [program, flag, script] = command as string[];
  if (command.length === 3 && /(^|\/)(ba|z|da|fi)?sh$/.test(program!) && /^-l?c$/.test(flag!)) return script;
  return (command as string[])
    .map((part) => (/^[\w@%+=:,./-]+$/.test(part) ? part : `'${part.replace(/'/g, "'\\''")}'`))
    .join(" ");
}

const CLAIM_KINDS = new Set(["tests", "build", "lint", "typecheck", "ran"]);
const CLAIM_VERDICTS = new Set(["backed", "failed", "none"]);

/// The claims of a `claim_checks` record a page can draw; one of a kind or verdict this page does
/// not know draws nothing.
export function readClaims(raw: unknown[]): ClaimCheck[] {
  return raw.flatMap((item): ClaimCheck[] => {
    const claim = item as Record<string, unknown> | null;
    if (!claim || typeof claim.text !== "string" || !claim.text.trim()) return [];
    if (!CLAIM_KINDS.has(String(claim.kind)) || !CLAIM_VERDICTS.has(String(claim.verdict))) return [];
    return [
      {
        text: claim.text,
        kind: claim.kind as ClaimCheck["kind"],
        verdict: claim.verdict as ClaimCheck["verdict"],
        ...(typeof claim.toolCallId === "string" ? { toolCallId: claim.toolCallId } : {}),
        ...(typeof claim.command === "string" ? { command: claim.command } : {}),
      },
    ];
  });
}

/// A finished shell call's exit status: `rawOutput.exit_code` (Codex; acpmux puts the others'
/// there too, hub/tool_shell.rs), else where an agent reported it in a record logged before acpmux
/// did: pi's `_meta.terminal_exit.exit_code`, OpenCode's `rawOutput.metadata.exit`.
function exitCode(update: any): number | undefined {
  const raw = update.rawOutput;
  const code = raw?.exit_code ?? raw?.exitCode ?? update._meta?.terminal_exit?.exit_code ?? raw?.metadata?.exit;
  return typeof code === "number" ? code : undefined;
}

/// pi (pi-acp) streams a bash call's output only as `_meta.terminal_output.data`, each update the
/// part printed since the last (the terminal-in-a-tool-call `_meta` extension): it adds to what
/// the call printed so far. Undefined for an update without it.
function terminalOutput(update: any, before: string | undefined): string | undefined {
  const data = update._meta?.terminal_output?.data;
  return typeof data === "string" && data ? (before ?? "") + data : undefined;
}

/// Codex reports a shell call's output in `rawOutput` when the call carries no content.
function formattedOutput(rawOutput: any): string {
  const text = rawOutput?.formatted_output;
  return typeof text === "string" ? text : "";
}

export function textFromContent(content: any): string {
  if (typeof content === "string") return content;
  if (content?.type === "text") return String(content.text ?? "");
  // A tool call's content blocks wrap their text: `{ type: "content", content: { type: "text" } }`.
  if (content?.type === "content") return textFromContent(content.content);
  if (Array.isArray(content)) return content.map(textFromContent).join("");
  return "";
}

/// The largest image block a tool call keeps (its base64 text): a bigger one is left out.
const MAX_TOOL_IMAGE_LENGTH = 8 * 1024 * 1024;

/// The data URLs of ACP `image` content blocks (`{type: "image", mimeType, data}`, bare or in a
/// `content` wrapper), images only and each under the cap.
function imagesFromContent(content: any): string[] | undefined {
  const found: string[] = [];
  const visit = (block: any) => {
    if (Array.isArray(block)) return block.forEach(visit);
    if (block?.type === "content") return visit(block.content);
    if (block?.type !== "image" || typeof block.data !== "string") return;
    const type = String(block.mimeType ?? "");
    if (/^image\/(png|jpeg|gif|webp)$/.test(type) && block.data.length <= MAX_TOOL_IMAGE_LENGTH)
      found.push(`data:${type};base64,${block.data}`);
  };
  visit(content);
  return found.length ? found : undefined;
}

/// A thought chunk continues the thought it follows: a thought streams into one growing item,
/// not one row per chunk. `at` (the chunk's time) dates the thought's first and latest chunk, so
/// a folded thought can read "Thought for 12s" (conversation/ThoughtRow.tsx `thoughtDuration`).
export function appendThought(items: AcpmuxActivity[], text: string, at?: number): AcpmuxActivity[] {
  const last = items.at(-1);
  if (last?.kind === "thought" && !last.tool)
    return [...items.slice(0, -1), { ...last, text: last.text + text, ...(at !== undefined && { endedAt: at }) }];
  return [...items, { kind: "thought", text, ...(at !== undefined && { startedAt: at, endedAt: at }) }];
}
