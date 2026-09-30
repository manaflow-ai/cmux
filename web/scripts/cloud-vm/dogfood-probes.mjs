const PROBE_TIMEOUT_MS = 30_000;
const PROBE_POLL_MS = 250;

function remainingMs(deadline, now) {
  const remaining = Math.ceil(deadline - now());
  if (remaining <= 0) throw new Error(`timed out after ${PROBE_TIMEOUT_MS}ms`);
  return remaining;
}

function commandOutput(response, what) {
  if (response.code !== 0) {
    throw new Error(`${what} failed (${response.code}): ${response.stderr.slice(-400)}`);
  }
  return response.stdout;
}

async function readHost(runtime, argv, deadline) {
  const response = await runtime.runTui(
    ["--socket", runtime.localSocket, "--json", ...argv],
    remainingMs(deadline, runtime.now),
  );
  const output = commandOutput(response, argv.join(" "));
  const records = JSON.parse(output);
  if (!Array.isArray(records)) throw new Error(`${argv.join(" ")} did not return a JSON array`);
  return records;
}

async function pollHost(runtime, deadline, observation, read, matches) {
  for (;;) {
    remainingMs(deadline, runtime.now);
    try {
      const snapshot = await read();
      observation.lastSeen = snapshot;
      for (const record of snapshot) {
        if (record.state && !observation.statesSeen.includes(record.state)) {
          observation.statesSeen.push(record.state);
        }
      }
      if (runtime.now() < deadline && matches(snapshot)) return;
    } catch (error) {
      observation.lastSeen = { error: error.message.slice(0, 600) };
    }
    await runtime.sleep(Math.min(PROBE_POLL_MS, remainingMs(deadline, runtime.now)));
  }
}

async function probe(runtime, name, details, work) {
  return runtime.timed(name, async () => {
    const startedAt = runtime.now();
    const observation = { ...details, statesSeen: [], lastSeen: null };
    try {
      await work(startedAt + PROBE_TIMEOUT_MS, observation);
      return { ...observation, ok: true, elapsedMs: Math.round(runtime.now() - startedAt) };
    } catch (error) {
      const message = error.message.slice(0, 600);
      runtime.note(`${name} failed: ${message}; last seen ${JSON.stringify(observation.lastSeen)}`);
      return { ...observation, ok: false, elapsedMs: Math.round(runtime.now() - startedAt), error: message };
    }
  });
}

async function hookStatus(runtime) {
  const marker = `${runtime.marker}-hooks`;
  const done = `${marker}-done`;
  const statusCommand = [
    "status=$(cmux --json agent hook status claude codex | tr -d '\\n');",
    `printf '%s\\n' \"$status\" | sed -n 's/.*\"provider\":\"claude\"[^}]*\"state\":\"\\([^\"]*\\)\".*/${marker}-claude:\\1/p';`,
    `printf '%s\\n' \"$status\" | sed -n 's/.*\"provider\":\"codex\"[^}]*\"state\":\"\\([^\"]*\\)\".*/${marker}-codex:\\1/p'`,
    `; printf '\\n%s\\n' '${done}'`,
  ].join(" ");
  return probe(runtime, "agentHooks", { providers: { claude: null, codex: null } }, async (deadline, observation) => {
    await runtime.typeLine(
      runtime.terminal,
      statusCommand,
      remainingMs(deadline, runtime.now),
    );
    try {
      await runtime.waitForScreen(
        runtime.localSocket,
        runtime.terminal,
        done,
        remainingMs(deadline, runtime.now),
      );
    } catch (error) {
      const remaining = deadline - runtime.now();
      if (remaining > 0) {
        const screen = await runtime.runTui(
          ["--socket", runtime.localSocket, "terminal", runtime.terminal, "screen", "read"],
          Math.min(1_000, Math.ceil(remaining)),
        );
        observation.lastSeen = { screen: screen.stdout.slice(-2000), error: error.message.slice(0, 400) };
      } else {
        observation.lastSeen = { error: error.message.slice(0, 400) };
      }
      throw error;
    }
    const screen = await runtime.runTui(
      ["--socket", runtime.localSocket, "terminal", runtime.terminal, "screen", "read"],
      remainingMs(deadline, runtime.now),
    );
    const output = commandOutput(screen, "hook status screen read");
    observation.lastSeen = output.slice(-2000);
    for (const provider of ["claude", "codex"]) {
      const state = output.match(new RegExp(`${marker}-${provider}:([a-z]+)`))?.[1] ?? "unknown";
      if (state === "unknown") throw new Error(`missing ${provider} hook status`);
      observation.providers[provider] = { installed: state === "installed", state };
    }
  });
}

async function agentStatus(runtime, name, event, expectedState) {
  return probe(runtime, name, { event, expectedState, emitToHostMs: null }, async (deadline, observation) => {
    const startedAt = runtime.now();
    const payload = JSON.stringify({ session_id: runtime.marker });
    await runtime.typeLine(
      runtime.terminal,
      `printf '%s' '${payload}' | cmux agent hook emit --source claude --event ${event}`,
      remainingMs(deadline, runtime.now),
    );
    await pollHost(runtime, deadline, observation,
      async () => (await readHost(runtime, ["agent", "list"], deadline))
        .filter((record) => record.surface === runtime.terminal),
      (records) => records.some((record) => record.state === expectedState && record.source === "hook"),
    );
    observation.emitToHostMs = Math.round(runtime.now() - startedAt);
  });
}

async function notification(runtime) {
  const title = runtime.marker;
  return probe(runtime, "notifyReachesHost", { title, emitToHostMs: null }, async (deadline, observation) => {
    const startedAt = runtime.now();
    await runtime.typeLine(runtime.terminal, `cmux notify --title ${title} --body probe`, remainingMs(deadline, runtime.now));
    await pollHost(runtime, deadline, observation,
      () => readHost(runtime, ["notification", "list"], deadline),
      (records) => records.some((record) => record.title === title),
    );
    observation.emitToHostMs = Math.round(runtime.now() - startedAt);
  });
}

export async function runAgentProbes(options) {
  const runtime = {
    now: () => performance.now(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    ...options,
  };
  return {
    agentHooks: await hookStatus(runtime),
    agentStatusWorking: await agentStatus(runtime, "agentStatusWorking", "UserPromptSubmit", "working"),
    agentStatusIdle: await agentStatus(runtime, "agentStatusIdle", "Stop", "idle"),
    notifyReachesHost: await notification(runtime),
  };
}
