# Notice to PL-acpmux: the asksBeforeTools claim and the launch digest (2026-11-09)

Owner W5-L, lead decisions of 2026-11-09. Read with #39648 and its follow-up PR (branch
`acpmux-claim-digest-remote`).

## What changed
- #39648: an ACP agent's `agentCapabilities._meta.acpmux.asksBeforeTools` claim holds a narrow
  policy only when acpmux started the agent from a harness entry of its own config
  (`Config::profile`), and only while the entry's `launch_digest` (argv and env) equals the one the
  agent started from (`policy_mode.rs` `claim_distrust`: `not_started_here`, `not_a_config_entry`,
  `entry_changed`). Each claim is logged as the session event `asks_before_tools_claim
  {harness, trusted, reason}`. An import, and a start with a different launch, drop the copied
  `agent_capabilities`. `require_enforced` takes `&Config`.
- Follow-up: a remote chat records the digest of its entry as the entry is written
  (`Resolved::launch_digest`, taken before `admit_remote_profile` resolves the program to its
  canonical path). `claim_distrust` compares digests only and reads no file, and a catalog reload
  that changes nothing no longer marks a remote chat `respawn_pending` (`profile_respawn.rs`).

- Second follow-up (branch `acpmux-claim-launch-inputs`, stacked on the first): the open items
  below, each with a red test (`tests/start_mode.rs` module `claim_launch`), then the fix. Each
  start records either a claim basis (`SessionMeta::claim_basis`: a digest of the entry's
  `launch_digest`, its `defaults` env with the preset env over it, and the preset's approval
  digest, `hub/claim_basis.rs` `config_inputs`, read with the profile) or why the start cannot
  carry a claim (`SessionMeta::claim_unbelieved`). `claim_distrust` gives the recorded reason, or
  compares the recorded basis with the config now. New reasons: `argv_skips_approvals`,
  `launch_reads_folder`.

## Items found by the audit, and their status
- The digest was taken before `${cwd}`/`${home}` expansion. Fixed: each start judges the launch
  as the config chose it, after expansion and before acpmux's own additions
  (`hub/claim_basis.rs` `unbelieved_launch`). It gives `launch_reads_folder` for: a package
  runner (`npx`, `bunx`, `pnpx`, `npm`, `pnpm`, `yarn`, `bun`, `deno`, `uv`, `uvx`, `pipx`); a
  relative program with a folder in it, or an absolute program inside the folder; Python with
  `-m`, `-c` or no script (not with `-P` or `PYTHONSAFEPATH`); Node with `-e`/`-p` or a preload
  by a name that is no absolute path; an argument or flag value (`--flag=v`, `-rv`) inside the
  folder or naming a file of it; an env value or part that is inside the folder, `.`, `..`,
  `./x`, `../x`, a relative path to a file of the folder, or any relative or empty entry of a
  `*PATH` list; a `PATH` entry (the entry's own as written, then the login shell's,
  `login_env::with_agent_path`) that is empty or relative; a bare program that `PATH` resolves to
  a file whose real path is inside the folder (a link to a program outside is that program). A
  chat in the home folder counts `~/.local/bin/agent` as the folder's (fail closed).
- An argv pin that skips approvals (`--yolo`, `--dangerously-skip-permissions`, every flag of
  `subsession_guard::argv_full_access`) did not cancel the claim. Fixed: `argv_skips_approvals`.
  `${model}` is expanded first, so a model value cannot add such a flag unseen.
- The preset env and the `defaults` env were outside the digest. Fixed: they are in the claim
  basis, so a change after the start gives `entry_changed`. The chat's own env
  (`session_env.rs`) is not: its allowlist holds no key that changes what runs.
- A pooled agent taken after its entry changed: no gap found. The pool key holds the final argv,
  an env hash and the preset system prompt sha, and a creation takes only an entry whose key
  equals the one its own resolved profile gives; `session_pool.rs`
  `hints_are_debounced_and_a_config_change_is_never_served` proves a changed entry is never
  served. The claim basis comes from the same resolved profile.
- Found in review: the config was read twice in one start (the profile, then the preset), so an
  edit and a revert in between could record one basis while the agent ran the other. Fixed: the
  basis is read under the same config read as the preset (`claim_basis::start_claim`), and a
  start whose entry or `defaults` env changed since it resolved them records `entry_changed`.
  Also: a start whose claim basis differs from the last one drops the copied
  `agent_capabilities`, so an older agent's claim is never judged by the new basis.
- A folder profile shadowed by a config entry of its name. Fixed: a folder-profile start records
  `not_a_config_entry`, which holds for that agent whatever the config gives later.

- Review of #40158 (w5l-rev-1): an absolute path is judged by where it leads (links resolved,
  `/tmp` is `/private/tmp`; on a volume that ignores case, another case is the same folder); an
  argument counts as a path only with a slash or as the script an interpreter runs (no false
  refusal for `opencode acp` or `.`); `not_started_here` tells the person to restart the chat.
- Delta review of #40158 (delta-rev-3) and the codex review (F3, F4). The bare-word rule passed
  launches that run a folder file. Fixed (fail closed): a bare word that names something the
  folder holds counts when acpmux cannot tell that it is no path: an option's value
  (`--config agent.json`, `--config=agent.json`), or any word of a launch that names an
  interpreter (`python3 -I agent.py`) or a wrapper (`env`, `nice`, `timeout`, ...). Under a
  wrapper every later word is judged as the program it may run (`env python3 -m agent`). Python's
  options are read as clusters (`-um` is a module run), `-I` keeps the safe path, and `-E` drops
  `PYTHONSAFEPATH`. A bare preload name in `NODE_OPTIONS` (`--require hook`) is the folder's. A
  bare word of another program that follows no option (`opencode acp`, `agent .`) is still taken
  as a subcommand or the program's own argument.

- Review of #40158 (w5l-158-rev-2): the wrapper rule failed open (unknown wrappers such as
  `pyenv exec`, `mise exec --`, `sandbox-exec`, `op run --`; `env`'s `KEY=VALUE`, `-u` and `-i`
  words; `node agent` with `agent.js`; `node --run`; PyPy). Lead decision: stop adding cases and
  decide fail closed. Fixed: a launch reads nothing of the folder only when acpmux understands
  every word of it (`claim_basis.rs` `Launch::understood`): a program by an absolute path outside
  the folder or a bare name that `PATH` does not resolve into it, and no package runner; a wrapper
  of a closed list whose own options it parses fully (`env` with its `KEY=VALUE` words judged as
  env and `-u`/`-i` applied, `nice`, `nohup`, `timeout`, `stdbuf`, `time`, `caffeinate`,
  `setsid`); Python with options of a safe list and a script by an absolute path outside the
  folder, or a module, code or stdin with the safe path (`-P`, `-I`, or `PYTHONSAFEPATH` on a
  Python known to be 3.11 or later, `python3.12`, not `python3`); Node with options of a safe list
  and a script by an absolute path outside the folder; a script interpreter with no option and
  such a script. Any other word that names an interpreter, a wrapper or a runner, any unknown
  option of those, a relative script, a shell's command string (`sh -c`, `bash -lc`) and PyPy
  count as reading the folder.
- Delta review of #40158 (w5l-delta-rev): the fix still failed open by names (`perl5.34`,
  `tclsh8.5`, `node22`, `osascript`; `PYTHON3` and `NODE` on a volume that ignores case; a runner
  inside a composite word such as `-c mcp_servers.x.command=node` or inline JSON; env names such
  as `RUBYOPT`, `BASH_ENV`, `PYTHONHOME`, `DYLD_INSERT_LIBRARIES`). Lead decisions: "agent CLIs
  plus 2 interpreters" and "strict names, change fixtures". Fixed in `claim_basis.rs`:
  - Program allowlist (`Program`, `Launch::program`): `opencode` and `codex` (with their own
    arguments), CPython 3 (`python3`, `python3.N`) and Node in their strict forms, and the wrappers
    of before. The written name and the real file's name (links resolved) must give the same kind,
    case folded. Every other program refuses, also one acpmux cannot find.
  - Argument parts (`Launch::parts_understood`): every argument word is split on whitespace,
    quotes, brackets and `=`, `:`, `,`, `;`. A part that names a runner (case folded, any version),
    an absolute path to a program, or a bare word that `PATH` resolves refuses, as does a part that
    is a path in the folder. The value literals `true`, `false`, `yes`, `info` are no program only as
    a value (a later part of a word, or the word after an option), never as the program, a bare
    word after no option, or under a command key (`--hook info`, `command=true`) (lead).
  - Env allowlist (`env_kept`): `PATH`, `LANG`, `LANGUAGE`, `LC_*`, `TERM`, `COLORTERM`,
    `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR`, `TZ`, `RUST_LOG`, `RUST_BACKTRACE`, `PYTHONUNBUFFERED`,
    `PYTHONDONTWRITEBYTECODE`, `PYTHONIOENCODING`, `PYTHONSAFEPATH`, `PYTHONNOUSERSITE`,
    `NODE_ENV`, `NODE_NO_WARNINGS`, `ACPMUX_AGENT_TOOLS` and names that end in `_API_KEY`,
    `_AUTH_TOKEN`, `_BASE_URL`, `_MODEL`, each with a value that names nothing of the folder.
    Every other name refuses (also `PYTHONPATH`, `NODE_OPTIONS`, `HOME`). The test fake agent now
    takes its `FAKE_*` settings as `--fake KEY VALUE` words, not env (no product exception).
- Delta SHIP at 2fc67b6b (w5l-delta-rev), lead additions, fail closed: an argument word with a
  backslash refuses (an escape such as `\u006eode` in a TOML or JSON value can spell a program past
  the part checks). The folder rule (a program that `PATH` finds in the folder) and the relative or
  empty `PATH` entry rule have tests on `opencode`, of the program allowlist, so only those rules
  can refuse them.
- Known limit: acpmux does not read an agent CLI's own config outside the launch, such as
  `~/.codex/config.toml` (its `mcp_servers`, `notify`) or opencode's global config. A program those
  files start is not judged; the claim believes the agent CLI as the lead accepted.
- Delta review at d2e3f400 (w5l-delta-rev, BLOCK): acpmux did not read the code after Python's
  `-c`, so `python3.12 -I -c "exec(open('agent.py').read())"` kept the claim. Lead decision, an
  allowlist: Python `-c` refuses in every form (`-c CODE`, `-cCODE`, `-Ic`), and `-m` keeps the
  claim only for a module of `PYTHON_MODULES`, which is empty (no supported agent CLI is launched
  by `python -m`), so every module refuses (`timeit -s`, `pdb`, `runpy`, `cProfile`, ...). A script
  by an absolute path outside the folder and code from stdin with the safe path keep it.
- Known limit: shell quote joining (`n''ode`) is not undone. No supported agent CLI passes an
  argument word to a shell today.
## Still open
- F1 (codex review of #40158, deferred by the lead, cmux#40605): a pooled agent is judged at
  take time. The pool prewarm spawns with no claim (`spawn.rs` `spawn_profile_for`,
  `claim_from = None`), and the take judges the folder as it is then, after the agent ran: an
  agent that runs `agent.py` from the folder and then deletes it is believed when it is taken.
- A bare word of a program that is no interpreter or wrapper, and that follows no option, is
  taken as no path (`opencode acp`), the one assumption the lead accepted. A program that reads
  such a word as a file of the folder is not judged by it.
- A config entry that runs its agent through `sh -c`, `bash -lc`, an unknown wrapper or
  `python3` with only `PYTHONSAFEPATH` keeps no `asksBeforeTools` claim (fail closed), also when
  the person wrote it on purpose.
- A `PATH` folder inside the chat folder that does not hold the agent's program is not judged:
  the agent's own subprocesses (not its tool calls, which ask) can find programs there.
- Other interpreters that load code from the working folder (Ruby `-I.`, Perl, a shell script
  that `cd`s) are judged only by their arguments and env. A wrapper script outside the folder can
  still run folder code; the person who writes the config entry chose that.
- A config entry that names an absolute path inside the chat folder is judged the folder's
  (fail closed), also when the person wrote that path on purpose.
