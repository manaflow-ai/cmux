/**
 * ~/README.md on every Cloud machine: what this machine is and how an agent (or a person) gets
 * more. Leo (2026-11-25): "but what if we want even more than the 32vcpu machines? how can an
 * agent know/ask for more capacity?", then "when they're on the vm that is".
 *
 * No numbers here: the sizes, prices and times live in one Rust source (acpmux
 * `agent_card_can_get.rs`) and `cmux capabilities` prints them, so this file cannot go stale.
 */
import { DEVBOX_WORK_HOME } from "../../services/vms/images/workUser";

export const HOME_README_PATH = `${DEVBOX_WORK_HOME}/README.md`;

export const HOME_README = `# This is a cmux Cloud machine

A Linux VM that cmux started for you. Your chats run here; edits sync back to your Mac.

What it has and what you can get:

    cmux capabilities          # this machine, the larger sizes, fan-out, Mac/GPU, rough $ and time
    cmux capabilities --json   # the same, for scripts

Both run locally: no token, no sign-in. \`nproc\`, \`free -h\` and \`df -h ~\` say the same live.

Need more (more vCPU or RAM, several machines, a Mac or a GPU):

    cmux machine request --vcpu N --mem M [--fanout K] [--kind mac|gpu] --for "why" --until ...

\`cmux capabilities\` says whether this build has \`cmux machine request\` yet. Until it does, tell
the person what you need and why; they pick a size or a plan.
`;

export function homeReadmeFile(): { path: string; text: string; mode: number } {
  return { path: HOME_README_PATH, text: HOME_README, mode: 0o644 };
}
