/**
 * Hand-rolled argument parser for cmux101.
 *
 * Usage:
 *   cmux101 [flags] [prompt]
 *   cmux101 auth login <provider>
 *   cmux101 auth logout <provider>
 *   cmux101 models [provider]
 */

export interface ParsedArgs {
  mode: "tui" | "print" | "auth" | "models" | "version" | "help" | "init" | "doctor" | "sessions";
  prompt?: string;
  model?: string;
  provider?: string;
  cwd?: string;
  resume?: string;
  permissionMode?: "default" | "auto" | "plan";
  showThinking?: boolean;
  showCost?: boolean;
  authSubcommand?: { provider: string; key?: string; action: "login" | "logout" };
  extraTools?: string[];
  print?: boolean;
  quiet?: boolean;
  outputFormat?: "text" | "json";
  /** init subcommand options */
  initOptions?: { force: boolean };
}

export function parseArgs(argv: string[]): ParsedArgs {
  const result: ParsedArgs = { mode: "tui" };
  const positional: string[] = [];
  let i = 0;

  // Helper to consume next token
  function nextToken(flag: string): string {
    i++;
    if (i >= argv.length) {
      throw new Error(`Flag ${flag} requires a value`);
    }
    return argv[i];
  }

  while (i < argv.length) {
    const arg = argv[i];

    switch (arg) {
      case "--version":
      case "-v":
        result.mode = "version";
        break;

      case "--help":
      case "-h":
        result.mode = "help";
        break;

      case "-p":
      case "--print":
        result.print = true;
        result.mode = "print";
        break;

      case "-m":
      case "--model":
        result.model = nextToken(arg);
        break;

      case "--provider":
        result.provider = nextToken(arg);
        break;

      case "--cwd":
        result.cwd = nextToken(arg);
        break;

      case "--resume":
        result.resume = nextToken(arg);
        break;

      case "--show-thinking":
        result.showThinking = true;
        break;

      case "--show-cost":
        result.showCost = true;
        break;

      case "--quiet":
        result.quiet = true;
        break;

      case "--output-format":
        {
          const fmt = nextToken(arg);
          if (fmt !== "text" && fmt !== "json") {
            throw new Error(`--output-format must be 'text' or 'json', got: ${fmt}`);
          }
          result.outputFormat = fmt;
        }
        break;

      case "--auto":
        result.permissionMode = "auto";
        break;

      case "--plan":
        result.permissionMode = "plan";
        break;

      case "--force":
        if (result.initOptions) {
          result.initOptions.force = true;
        } else {
          result.initOptions = { force: true };
        }
        break;

      case "--tool":
        {
          const tool = nextToken(arg);
          result.extraTools = result.extraTools ?? [];
          result.extraTools.push(tool);
        }
        break;

      default:
        if (arg.startsWith("-")) {
          throw new Error(`Unknown flag: ${arg}`);
        }
        positional.push(arg);
        break;
    }

    i++;
  }

  // Dispatch subcommands from positionals
  if (positional.length === 0) {
    // mode stays as whatever flags set (version/help/tui/print)
    return result;
  }

  const [first, second, third] = positional;

  if (first === "auth") {
    result.mode = "auth";
    if (second === "login" || second === "logout") {
      if (!third) {
        throw new Error(`auth ${second} requires a <provider> argument`);
      }
      result.authSubcommand = { provider: third, action: second };
    } else if (second) {
      throw new Error(`Unknown auth subcommand: ${second}. Use 'login' or 'logout'.`);
    }
    return result;
  }

  if (first === "models") {
    result.mode = "models";
    if (second) {
      result.provider = result.provider ?? second;
    }
    return result;
  }

  if (first === "init") {
    result.mode = "init";
    if (!result.initOptions) {
      result.initOptions = { force: false };
    }
    return result;
  }

  if (first === "doctor") {
    result.mode = "doctor";
    return result;
  }

  if (first === "sessions") {
    result.mode = "sessions";
    return result;
  }

  // Otherwise, treat positionals as prompt text
  const promptText = positional.join(" ");
  result.prompt = promptText;

  // If --print / -p was used, mode is already "print"
  if (result.mode !== "print" && result.mode !== "version" && result.mode !== "help") {
    result.mode = result.print ? "print" : "tui";
  }

  return result;
}
