const escape = "\u001b";
const userInputColor = `${escape}[38;5;245m`;
const resetColor = `${escape}[0m`;
const ansiPattern = /\u001b\[[0-?]*[ -/]*[@-~]/;
const userInputLinePattern = /^(\s*)(?:[$>]\s+\S|\u203a\s+\S)/;

export function decoratePlainTerminalText(text: string) {
  if (!text || ansiPattern.test(text)) return text;
  return text
    .split("\n")
    .map((line) => {
      if (!userInputLinePattern.test(line)) return line;
      return `${userInputColor}${line}${resetColor}`;
    })
    .join("\n");
}
