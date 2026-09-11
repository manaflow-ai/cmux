#!/usr/bin/env bun
import { loadHomeState } from "./data";
import { renderSummary } from "./summary";
import { runInteractiveHome } from "./tui";

interface CliOptions {
  data?: string;
  help: boolean;
  once: boolean;
}

const helpText = `cmux home

Usage:
  cmux-home [--data <json-or-path>] [--once]
  cmux-home --help

Options:
  --data <json-or-path>  Load inline JSON or a JSON file.
  --once                 Print a deterministic summary and exit.
  --help                 Show this help.
`;

export async function main(argv = Bun.argv.slice(2)): Promise<void> {
  const options = parseArgs(argv);
  if (options.help) {
    process.stdout.write(helpText);
    return;
  }

  const state = loadHomeState({ data: options.data });
  if (options.once) {
    process.stdout.write(renderSummary(state));
    return;
  }

  await runInteractiveHome(state);
}

export function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = { help: false, once: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--help":
      case "-h":
        options.help = true;
        break;
      case "--once":
        options.once = true;
        break;
      case "--data": {
        const value = argv[index + 1];
        if (!value) {
          throw new Error("--data requires a JSON string or file path");
        }
        options.data = value;
        index += 1;
        break;
      }
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }
  return options;
}

if (import.meta.main) {
  void main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`cmux home failed: ${message}\n`);
    process.exit(1);
  });
}
