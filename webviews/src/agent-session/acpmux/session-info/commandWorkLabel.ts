// A command substitution runs work; it is never an environment prefix to cut halfway through.
// The send parser already keeps quotes, escapes and nested substitutions whole. Reuse that lexer
// to name the work in a complex command, leaving the exact shell line in its tooltip and output.
import { shellCommands, type ShellCommand } from "../conversation/acpmuxSends";

const ASSIGNMENT = /^[A-Za-z_]\w*=/;

/// The program and its leading plain operands, without options, paths or shell expansions. This
/// names the operation (`cmux-ci run`), rather than exposing its long flags and interpolation.
function operation(command: ShellCommand): string | undefined {
  const words = command.words;
  let at = words[0]?.text === "env" && !words[1]?.text.startsWith("-") ? 1 : 0;
  while (at < words.length && ASSIGNMENT.test(words[at]!.text)) at += 1;
  const program = words[at];
  if (!program) return undefined;
  if (!program.literal) return "…"; // an expanded program is not known from the command line
  const names = [program.text.split("/").pop()!];
  for (const word of words.slice(at + 1)) {
    if (!word.literal || !/^[\w.+-]+$/.test(word.text) || word.text.startsWith("-")) break;
    names.push(word.text);
  }
  return names.join(" ");
}

/// A shell line with actual command substitutions, in words: `SHA=$(git rev-parse HEAD);
/// cmux-ci run --ref $SHA …` is `git rev-parse HEAD · cmux-ci run`. A substitution is executed
/// work, so it stays named alongside the outer command; a quoted or escaped `$(` is just text.
/// Undefined for ordinary commands: they keep their existing descriptive labels.
export function commandWorkLabel(text: string): string | undefined {
  if (!/\$\(|`/.test(text)) return undefined;
  const commands = shellCommands(text);
  if (!commands.some((command) => command.runs?.length)) return undefined;
  const pending: (ShellCommand | string)[] = [...commands].reverse();
  const labels: string[] = [];
  while (pending.length) {
    const command = pending.pop()!;
    if (typeof command === "string") {
      labels.push(command);
      continue;
    }
    const words = command.words;
    const plainSetup =
      !command.writes &&
      ((words[0]?.text === "cd" && words.length === 2 && words[1]!.literal) ||
        (words[0]?.text === "export" && words.slice(1).every((word) => ASSIGNMENT.test(word.text))));
    const label = plainSetup ? undefined : operation(command);
    // A redirect with no program still writes a file; retain the full line rather than hiding
    // that work behind the title of its substitution.
    if (!label && command.writes) return text;
    if (label) pending.push(label);
    // Stack order puts each substitution before the command that consumes its answer. Iterative,
    // so deeply nested shell input does not grow the JavaScript call stack.
    for (const run of [...(command.runs ?? [])].reverse())
      for (const nested of [...shellCommands(run)].reverse()) pending.push(nested);
  }
  return labels.join(" · ") || undefined;
}
