// A bounded walk over sanitized shell text. This is evidence extraction, not shell execution:
// literal predicates are known; external command statuses remain unknown. Never execute input.
type Status = boolean | undefined;
const invert = (value: Status): Status => (value === undefined ? undefined : !value);

export function shellCommands(text: string): string[] {
  text = text.replace(/\\\n/g, "");
  const tokens = text.match(/&&|\|\||\$\(|[;\n&|()]|(?:(?:\\[^\s]|(?!\$\()[^\s;&|()]))+/g) ?? [];
  const commands: string[] = [];
  let at = 0;
  const list = (active: boolean, stops: readonly string[], depth: number): Status => {
    if (depth > 64) {
      at = tokens.length;
      return undefined;
    }
    let status: Status;
    let operator = ";";
    while (at < tokens.length && !stops.includes(tokens[at]!)) {
      const token = tokens[at]!;
      if ([";", "\n", "&", "&&", "||", "|"].includes(token)) {
        if (token !== "\n" || !["&&", "||"].includes(operator)) operator = token;
        at++;
        continue;
      }
      const runs = active && (operator === "&&" ? status !== false : operator === "||" ? status !== true : true);
      const previous = at;
      const first = compound(runs, depth + 1);
      let result = first.status;
      // A short-circuit guard applies to every component of the following pipeline.
      while (tokens[at] === "|") {
        at++;
        while (tokens[at] === "\n") at++;
        result = compound(runs, depth + 1).status;
      }
      if (first.negate) result = invert(result);
      if (operator === "&&") {
        status = status === false || result === false ? false : status === true && result === true ? true : undefined;
      } else if (operator === "||") {
        status = status === true || result === true ? true : status === false && result === false ? false : undefined;
      } else status = result;
      operator = ";";
      if (at === previous) at++;
    }
    return status;
  };
  const compound = (active: boolean, depth: number): { status: Status; negate: boolean } => {
    let negate = false;
    while (tokens[at] === "!") {
      negate = !negate;
      at++;
    }
    let status: Status;
    if (tokens[at] === "if") {
      at++;
      let remaining = active;
      const outcomes: Status[] = [];
      while (at < tokens.length) {
        const condition = list(remaining, ["then", "fi"], depth);
        if (tokens[at] !== "then") {
          if (remaining) outcomes.push(undefined);
          if (tokens[at] === "fi") at++;
          break;
        }
        at++;
        const body = list(remaining && condition !== false, ["elif", "else", "fi"], depth);
        if (remaining && condition !== false) outcomes.push(body);
        if (condition === true) remaining = false;
        if (tokens[at] === "elif") {
          at++;
          continue;
        }
        if (tokens[at] === "else") {
          at++;
          const other = list(remaining, ["fi"], depth);
          if (remaining) outcomes.push(other);
          remaining = false;
        }
        if (tokens[at] === "fi") at++;
        break;
      }
      // An unmatched if succeeds. Combine all reachable arm results, retaining
      // certainty only when every possible path has the same status.
      if (remaining) outcomes.push(true);
      status = outcomes.length && outcomes.every((value) => value === outcomes[0]) ? outcomes[0] : undefined;
    } else if (["for", "while", "until"].includes(tokens[at] ?? "")) {
      const loop = tokens[at++]!;
      let runs = active;
      if (loop === "for") {
        // The variable and iterable are data, not executable commands. An explicitly
        // empty iterable never enters the body; positional arguments remain unknown.
        const header: string[] = [];
        while (at < tokens.length && ![";", "\n", "do"].includes(tokens[at]!)) header.push(tokens[at++]!);
        if (header[1] === "in" && header.length === 2) runs = false;
        while ([";", "\n"].includes(tokens[at] ?? "")) at++;
      } else {
        const condition = list(active, ["do", "done"], depth);
        runs = active && (loop === "while" ? condition !== false : condition !== true);
      }
      if (tokens[at] === "do") {
        at++;
        list(runs, ["done"], depth);
        if (tokens[at] === "done") at++;
      }
      // A loop may execute multiple times; retain no unsupported exit-status certainty.
      status = runs ? undefined : true;
    } else if (tokens[at] === "(") {
      at++;
      status = list(active, [")"], depth);
      if (tokens[at] === ")") at++;
    } else if (tokens[at] === "{") {
      at++;
      status = list(active, ["}"], depth);
      if (tokens[at] === "}") at++;
    } else if (tokens[at] === "}") {
      at++;
      status = undefined;
    } else {
      const words: string[] = [];
      let substitutionStatus: Status;
      while (at < tokens.length && ![";", "\n", "&", "&&", "||", "|", "(", ")"].includes(tokens[at]!)) {
        if (tokens[at] === "$(") {
          at++;
          substitutionStatus = list(active, [")"], depth);
          if (tokens[at] === ")") at++;
          words.push("$()");
        } else words.push(tokens[at++]!);
      }
      if (active && words.length) commands.push(`${negate ? "! " : ""}${words.join(" ")}`);
      status =
        words.length === 1 && ["true", "false", ":"].includes(words[0]!)
          ? words[0] !== "false"
          : words.length > 0 && words.every((word) => /^[A-Za-z_]\w*=$/.test(word) || word === "$()")
            ? substitutionStatus
            : undefined;
    }
    return { status, negate };
  };
  list(true, [], 0);
  return commands;
}

// Peel known wrappers by their argument grammar, so `timeout 60 echo gh ...` stays echo.
export function isPullRequestCommand(command: string): boolean {
  const words = command.trim().split(/\s+/);
  let at = 0;
  while (at < words.length) {
    const word = words[at]!;
    const name = word.slice(word.lastIndexOf("/") + 1);
    if (/^[A-Za-z_]\w*=/.test(word) || ["env", "command", "nohup", "time"].includes(name)) {
      at++;
      if (name === "env") {
        while (words[at]?.startsWith("-")) {
          const option = words[at++]!;
          if (option === "--") break;
          if (["-u", "--unset", "-C", "--chdir"].includes(option)) at++;
          else if (!["-", "-i", "--ignore-environment"].includes(option) && !/^--(?:unset|chdir)=/.test(option))
            return false;
        }
      } else if (name === "time" || name === "command") {
        if (words[at] === "-p") at++;
        if (words[at] === "--") at++;
      } else if (name === "nohup" && words[at] === "--") at++;
      continue;
    }
    if (word === "$(" || word === "$()") {
      at++;
      continue;
    }
    if (name !== "timeout") return ["gh", "glaeda-gh", "gh-merge-green"].includes(name);
    at++;
    while (words[at]?.startsWith("-")) {
      const option = words[at++]!;
      if (option === "--") break;
      if (["-k", "-s", "--kill-after", "--signal"].includes(option)) at++;
      else if (
        !["--foreground", "--preserve-status", "--verbose", "-v", "-p"].includes(option) &&
        !/^--(?:kill-after|signal)=/.test(option)
      )
        return false;
    }
    if (!/^\d+(?:\.\d+)?[smhd]?$/.test(words[at++] ?? "")) return false;
  }
  return false;
}
