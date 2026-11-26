// l10n-allow-file: gallery fixtures (sample repos, hosts, secret names) and design captions, not shipped UI.
//
// Move this to AutoCloud (MoveToAutoCloud.tsx): `cmux migrate plan --json` drawn as a card, three looks
// over the same fixtures. Leo, 2026-11-24: "we ought to be able to have good migration capabilities all
// around for people of all stages any and all levels of technical sophistication and teams and
// organizations of any size and demand to move to autocloud". The picked look is `summary` (MOVE_LOOK); the other two stay for comparison.
import { componentEntry } from "../../gallery/format";
import {
  MoveToAutoCloud,
  type MoveLook,
  type MovePlan,
  type MoveRun,
  type MoveToAutoCloudProps,
} from "./MoveToAutoCloud";

/// A small laptop: one repo with local work, a couple of dotfiles, an agent's settings.
const laptop: MovePlan = {
  version: 1,
  source: { kind: "laptop", label: "this Mac", id: "laptop:mbp-air" },
  projects: [
    {
      key: "~/src/notes-app",
      name: "notes-app",
      repo: {
        url: "https://github.com/you/notes-app.git",
        branch: "main",
        path: "~/src/notes-app",
        dirty_files: 3,
        unpushed_commits: 1,
      },
      machine: { setup: ["bun install"], check: ["bun test"] },
      chats: [
        { agent: "claude", path: "~/.claude/projects/-Users-you-src-notes-app" },
        { agent: "claude", path: "~/.claude/projects/-Users-you-src-notes-app-2" },
      ],
    },
    {
      key: "~/scratch/plot",
      name: "plot",
      repo: { path: "~/scratch/plot", dirty_files: 2 },
      machine: { setup: ["python3 -m venv .venv", "pip install -r requirements.txt"] },
      checked: false,
    },
  ],
  carry: [
    { kind: "shell", path: "~/.zshrc", bytes: 2_310 },
    { kind: "git-config", path: "~/.gitconfig", bytes: 412 },
    { kind: "agent-settings", path: "~/.claude/settings.json", bytes: 1_904, agent: "claude" },
    { kind: "shell-history", path: "~/.zsh_history", bytes: 812_000, checked: false },
  ],
};

/// A repo whose devcontainer becomes the machine's setup, with CI's secret names.
const devcontainer: MovePlan = {
  version: 1,
  source: { kind: "devcontainer", label: "atlas-web", id: "devcontainer:~/src/atlas-web" },
  projects: [
    {
      key: "~/src/atlas-web",
      name: "atlas-web",
      repo: { url: "https://github.com/acme/atlas-web.git", branch: "feat/billing", path: "~/src/atlas-web" },
      image: "mcr.microsoft.com/devcontainers/typescript-node:20",
      services: ["postgres", "redis"],
      ports: [3000, 5432],
      machine: {
        env: { NODE_ENV: "development" },
        secret_names: ["DATABASE_URL", "STRIPE_SECRET_KEY", "SENTRY_AUTH_TOKEN", "NPM_TOKEN"],
        setup: ["npm ci", "docker compose up -d postgres redis", "npm run db:migrate"],
        check: ["npm test"],
      },
      chats: [{ agent: "codex", path: "~/.codex/sessions/2026/11/atlas-web" }],
    },
  ],
  carry: [
    { kind: "editor", path: "~/Library/Application Support/Code/User/settings.json", bytes: 6_120 },
    { kind: "agent-login", path: "~/.codex/auth.json", agent: "codex" },
  ],
  warnings: ["feat/billing is 2 commits ahead of origin: they ride along as a bundle."],
};

/// A box reached over SSH, and Codespaces imported through `gh`.
const sshHost: MovePlan = {
  version: 1,
  source: { kind: "ssh-host", label: "devbox.acme.internal", id: "ssh:devbox.acme.internal" },
  projects: [
    {
      key: "/home/you/ml-train",
      name: "ml-train",
      repo: {
        url: "git@github.com:acme/ml-train.git",
        branch: "main",
        path: "/home/you/ml-train",
        unpushed_commits: 4,
      },
      machine: { secret_names: ["WANDB_API_KEY", "HF_TOKEN"], setup: ["uv sync"] },
      notes: ["The box has a GPU; pick a GPU size on the next step."],
    },
  ],
  carry: [{ kind: "ssh-config", path: "~/.ssh/config", bytes: 980 }],
};
const codespaces: MovePlan = {
  version: 1,
  source: { kind: "codespaces", label: "2 codespaces", id: "codespaces:you" },
  projects: [
    {
      key: "fluffy-space-x7p",
      name: "docs-site",
      repo: { url: "https://github.com/acme/docs-site.git", branch: "main" },
      machine: { secret_names: ["ALGOLIA_ADMIN_KEY"], setup: ["pnpm install"] },
    },
    {
      key: "sturdy-garden-q2",
      name: "api-gateway",
      repo: { url: "https://github.com/acme/api-gateway.git", branch: "rate-limits" },
      machine: { setup: ["go mod download"] },
    },
  ],
  unsupported: [
    {
      what: "Codespaces prebuilds",
      why: "AutoCloud machines are full VMs; the devcontainer's setup runs on create instead.",
    },
  ],
};

type Fixture = { plans: MovePlan[]; run?: MoveRun; headless?: boolean; note: string; height: number };

const moving: MoveRun = {
  state: "moving",
  projects: {
    "~/src/atlas-web": { stage: "done", first_chat_ms: 41_000 },
    "/home/you/ml-train": { stage: "moving", step: "Carrying 4 unpushed commits" },
    "fluffy-space-x7p": { stage: "pending" },
    "sturdy-garden-q2": { stage: "pending" },
  },
};
const moved: MoveRun = {
  state: "moved",
  undoId: "devcontainer:~/src/atlas-web",
  projects: { "~/src/atlas-web": { stage: "done", first_chat_ms: 41_000 } },
};
const failed: MoveRun = {
  state: "failed",
  projects: {
    "~/src/atlas-web": { stage: "done", first_chat_ms: 41_000 },
    "/home/you/ml-train": {
      stage: "failed",
      step: "Delivering secrets",
      error: "HF_TOKEN is not in this computer's keychain",
    },
    "fluffy-space-x7p": { stage: "pending" },
    "sturdy-garden-q2": { stage: "pending" },
  },
};

const FIXTURES: Record<string, Fixture> = {
  laptop: { plans: [laptop], note: "A small laptop: two folders (one off), dotfiles, Claude's settings.", height: 520 },
  devcontainer: {
    plans: [devcontainer],
    note: "A repo with a devcontainer: its image, services and ports become setup; four secrets by name.",
    height: 600,
  },
  "ssh-import": {
    plans: [sshHost, codespaces],
    note: "A box over SSH and two Codespaces imported; prebuilds stay behind, with why.",
    height: 680,
  },
  moving: {
    plans: [devcontainer, sshHost, codespaces],
    run: moving,
    note: "Moving: one moved (first reply in 41 s), one carrying its commits, two waiting.",
    height: 760,
  },
  moved: {
    plans: [devcontainer],
    run: moved,
    note: "Moved: the undo line, nothing on the source changed.",
    height: 560,
  },
  failed: {
    plans: [devcontainer, sshHost, codespaces],
    run: failed,
    note: "Failed: the step and why on its project, Retry goes on where it stopped.",
    height: 780,
  },
  headless: {
    plans: [laptop, sshHost],
    headless: true,
    note: "Headless (no signed-in app): the CLI line where Move was.",
    height: 680,
  },
};

const LOOKS: Record<MoveLook, string> = {
  checklist: "Checklist by what moves",
  sources: "One block per place the work is now",
  summary: "Picked: one line of counts, Review opens the list",
};

const noop = () => undefined;

const variants: Record<string, { note: string; props: MoveToAutoCloudProps; height?: number }> = {};
for (const look of Object.keys(LOOKS) as MoveLook[]) {
  for (const [name, fixture] of Object.entries(FIXTURES)) {
    // The summary stays one line until Review; its open variant shows the list.
    const summary = look === "summary";
    variants[`${look}-${name}`] = {
      note: `${LOOKS[look]}. ${fixture.note}`,
      height: summary && !fixture.plans.some((p) => p.warnings?.length) ? 260 : summary ? 300 : fixture.height,
      props: {
        look,
        plans: fixture.plans,
        run: fixture.run,
        headless: fixture.headless,
        onMove: noop,
        onRetry: noop,
        onNotNow: noop,
      },
    };
  }
}
variants["summary-review-open"] = {
  note: `${LOOKS.summary}. Review opened on the SSH host and Codespaces plan.`,
  height: 700,
  props: { look: "summary", plans: [sshHost, codespaces], reviewOpen: true, onMove: noop, onNotNow: noop },
};

function Board(props: MoveToAutoCloudProps) {
  return (
    <div className="move-ac-board">
      <MoveToAutoCloud {...props} />
    </div>
  );
}

export default componentEntry<MoveToAutoCloudProps>({
  id: "agent-pane.move-to-autocloud",
  title: "Move this to AutoCloud: the migrate plan card (designs)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/MoveToAutoCloud.tsx#MoveToAutoCloud"],
  keywords: ["autocloud", "cloud", "migrate", "move", "import", "codespaces", "ssh", "devcontainer", "secrets"],
  styles: () =>
    Promise.all([import("../../ui/controls.css"), import("./styles.css"), import("./MoveToAutoCloud.gallery.css")]),
  load: async () => Board,
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 600,
  anchors: [{ selector: ".move-ac" }],
  variants,
});
