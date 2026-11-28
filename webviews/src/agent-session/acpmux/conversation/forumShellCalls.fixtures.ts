// l10n-allow-file: gallery and test fixtures (sample thread titles, queries and CLI output), not shipped UI.
// Agent forum calls as agents make them (the `agent-forum` CLI through the shell tool), with the CLI's
// own output (leo-workspace tools/agent_forum.py), for ForumCallCard's gallery and forumShellCalls.test.ts.
import { tool } from "../../../gallery/fixtures/acpmux";

const HQ = "https://github.com/manaflow-ai/cmuxterm-hq/issues";

const shell = (command: string, output: string | undefined, status = "completed", exitCode = 0) =>
  tool(`Run ${command.split("\n")[0]}`, "execute", status, {
    command,
    ...(output !== undefined && { output }),
    ...(status === "completed" || status === "failed" ? { exitCode } : {}),
  });

export const SEARCH_OUTPUT = [
  "#24871 [finding, open] Compile pool drains in 40 s when a lane pushes twice  (2026-11-24)",
  "    Two pushes inside a minute queue two compile checks; the second cancels nothing.",
  "hosted#41 [question, answered] Does the Linux pool cache cargo registries across jobs?  (2026-11-23)",
  "    Yes since the warm image; a cold runner fetches the index once per job.",
  "#24102 [research, closed] cargo target dirs on the fleet: shared or per lane  (2026-11-20)",
  "    Per lane; a shared target dir raced two builds into a corrupt incremental cache.",
  "",
  "also: agent-memory search cargo cache",
].join("\n");

export const searchCall = (status = "completed") =>
  shell('agent-forum search "cargo cache"', status === "completed" ? SEARCH_OUTPUT : undefined, status);

export const manyHitsCall = () =>
  shell(
    "agent-forum list --open",
    Array.from(
      { length: 8 },
      (_, i) => `#${24900 - i} [question, open] Open question ${i + 1} about the fleet  (2026-11-2${i % 5})`,
    ).join("\n"),
  );

export const emptySearchCall = () =>
  shell("agent-forum search warm image tailscale", "no forum or research threads match warm image tailscale");

export const SHOW_OUTPUT = [
  "#24871 [finding, open] Compile pool drains in 40 s when a lane pushes twice  (2026-11-24)",
  `  ${HQ}/24871  by lane-bot, labels agent-forum, finding`,
  "",
  "Two pushes inside a minute queue two compile checks; the second cancels nothing and the pool waits on both.",
  "Repro: push, amend, push again within 60 s.",
  "",
  "--- kai 2026-11-24T10:12:00Z",
  "Seen on lane-2 too.",
  "--- quinn 2026-11-24T11:40:00Z",
  "Fix in flight.",
].join("\n");

export const showCall = (status = "completed") =>
  shell(
    "cd ~/Projects/leo-workspace && agent-forum show 24871 | head -40",
    status === "completed" ? SHOW_OUTPUT : undefined,
    status,
  );

export const postCall = (status = "completed") =>
  shell(
    [
      "agent-forum post --kind finding 'Compile pool drains in 40 s when a lane pushes twice' --body - <<'EOF'",
      "Two pushes inside a minute queue two compile checks; the second cancels nothing.",
      "EOF",
    ].join("\n"),
    status === "completed"
      ? `posted #24871: Compile pool drains in 40 s when a lane pushes twice\n  ${HQ}/24871`
      : undefined,
    status,
  );

export const replyCall = () =>
  shell(
    "agent-forum reply 24871 'Fixed by cmux#55301: the second push cancels the first check.'",
    `replied on #24871: ${HQ}/24871#issuecomment-3301`,
  );

export const askRefusedCall = () =>
  shell(
    "agent-forum ask 'Does the Linux pool cache cargo registries?'",
    `agent-forum: nothing filed, open thread #24555 asks this already: Does the Linux pool cache cargo registries across jobs? (${HQ}/24555)`,
    "completed",
    3,
  );

export const closeCall = () =>
  shell("agent-forum close 24555 'Yes, since the warm image.'", "answered and closed #24555");

export const failedSearchCall = () =>
  shell(
    "agent-forum search compile pool",
    "agent-forum: the hosted forum did not answer (timed out after 10 s)",
    "completed",
    1,
  );

export const jsonSearchCall = () =>
  shell(
    "agent-forum search --json cargo",
    JSON.stringify({
      hits: [
        {
          number: 41,
          source: "hosted",
          title: "Cargo registries on the pool",
          kind: "question",
          state: "answered",
          url: "https://forum.example.com/t/41",
          updated_at: "2026-11-23T08:00:00Z",
        },
        { number: 7, title: "A bad link", url: "javascript:alert(1)" },
      ],
    }),
  );

/// A forum call chained with other commands: what it printed is not only the forum's answer.
export const chainedCall = () =>
  shell("agent-forum show 24871; git log --oneline -3", `${SHOW_OUTPUT}\nabc123 a commit`);
