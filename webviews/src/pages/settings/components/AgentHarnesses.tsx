// Settings > Agents > Your Agents (BRING-YOUR-OWN-HARNESS H2), after the Harnesses card (cx-mg91)
// that lists every harness: the profiles you added, with Check (the doctor's steps inline) and
// Remove (Undo keeps the backup), and Add: one-click rows from the ACP Registry, or a custom
// command. The host runs each gesture through the same
// operations as the `agent.harness.*` actions (cmux.settings.agents.run) and sends the list live
// (cmux.settings.agents.changed) only while this card is mounted. The route's focus opens a panel:
// `agents.add` (Add ACP Agent…, the model picker's +) or `agents.registry`.
import { useCallback, useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Tabs } from "@base-ui/react/tabs";
import { StableLabel } from "../../../ui/StableLabel";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { parseHarnessIconSpec, rememberHarnessIcons } from "../../../agent-session/shared/harnessIcons";
import { useStore } from "../context";
import { Icon } from "../icons";
import { AGENTS_KEY, agentsQuery } from "../sectionQueries";
import type { AgentDoctorResult, AgentHarnessRow, AgentRegistryAgent, AgentsRun, AgentsState } from "../ops";
import { t } from "../strings";

type Panel = "registry" | "custom" | null;

const panelFor = (focus: string | null): Panel =>
  focus === "agents.registry" ? "registry" : focus === "agents.add" ? "custom" : null;

const field =
  "box-border h-7 w-full rounded-md border border-solid border-edge bg-transparent px-2 font-[inherit] text-[13px] text-fg outline-none placeholder:text-soft focus:border-accent-soft";

export function AgentHarnesses({ focus }: { focus: string | null }) {
  const store = useStore();
  const queryClient = useQueryClient();
  // The route's loader (or a hover on Agents) read the state; live pushes and gestures write it.
  const state = useQuery(agentsQuery(store)).data ?? null;
  const setState = useCallback((next: AgentsState) => void queryClient.setQueryData(AGENTS_KEY, next), [queryClient]);
  const [panel, setPanel] = useState<Panel>(() => panelFor(focus));
  const [seenFocus, setSeenFocus] = useState(focus);
  const [error, setError] = useState<string | null>(null);
  // A new route focus (the palette's Add ACP Agent… while Settings shows) opens its panel.
  if (focus !== seenFocus) {
    setSeenFocus(focus);
    if (panelFor(focus)) setPanel(panelFor(focus));
  }
  const live = useRef<{ stop?: () => void; alive: boolean }>({ alive: false });
  const mounted = useCallback(
    (node: HTMLDivElement | null) => {
      const session = live.current;
      if (!node) {
        session.alive = false;
        session.stop?.();
        session.stop = undefined;
        return;
      }
      session.alive = true;
      void store.watchAgents(setState).then((stop) => {
        if (session.alive) session.stop = stop;
        else stop();
      });
      void store.runAgents({ action: "refresh" });
    },
    [store, setState],
  );
  const run = useCallback(
    async (gesture: AgentsRun): Promise<boolean> => {
      setError(null);
      const reply = await store.runAgents(gesture);
      if (!reply.ok) setError(reply.error.message);
      const next = await store.agentsState();
      if (next) setState(next);
      return reply.ok;
    },
    [store, setState],
  );
  return (
    <div className="group" data-card="agentHarnesses" ref={mounted}>
      <div className="flex items-center gap-2">
        <h3 className="group-title m-0 flex-1">{t("settingsPage.agents.title")}</h3>
        {state?.manages !== false && (
          <button type="button" className="button" onClick={() => setPanel(panel ? null : "registry")}>
            {t("settingsPage.agents.add")}
          </button>
        )}
        <button type="button" className="button" onClick={() => void run({ action: "refresh" })}>
          {t("settingsPage.agents.refresh")}
        </button>
      </div>
      <p className="mt-1 mb-3 text-[12px] leading-[17px] text-muted" data-intro="">
        {t("settingsPage.agents.intro")}
      </p>
      {state && <AgentsBody state={state} panel={panel} setPanel={setPanel} run={run} />}
      {state?.status === "unreachable" && state.message && (
        <output className="my-2 block text-[12px] text-warning">{state.message}</output>
      )}
      {error && (
        <p className="my-2 text-[12px] text-danger" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}

function AgentsBody({
  state,
  panel,
  setPanel,
  run,
}: {
  state: AgentsState;
  panel: Panel;
  setPanel: (panel: Panel) => void;
  run: (gesture: AgentsRun) => Promise<boolean>;
}) {
  const added = state.harnesses.filter((row) => row.removable);
  // Each row's mark is the icon acpmux resolved for it (its own, else the agent it runs, else a
  // monogram), the same one the model picker, the tabs and Home draw.
  useEffect(() => {
    rememberHarnessIcons(state.harnesses.map((row) => ({ id: row.id, iconSpec: parseHarnessIconSpec(row.iconSpec) })));
  }, [state.harnesses]);
  return (
    <>
      {!state.manages && (
        <div className="mb-3 rounded-md bg-input px-3 py-2 text-[12px] text-muted" data-agents-cli>
          {t("settingsPage.agents.cli")}
          <code className="mt-1 block font-mono text-fg">cmux harness add --registry ID · cmux harness doctor ID</code>
        </div>
      )}
      {state.removed && (
        <output className="mb-2 flex items-center gap-2 rounded-md bg-input px-3 py-1.5 text-[13px]">
          <span className="flex-1">{t("settingsPage.agents.removed", state.removed.id)}</span>
          <button
            type="button"
            className="button"
            onClick={() => void run({ action: "restore", backup: state.removed!.backup })}
          >
            {t("settingsPage.agents.undo")}
          </button>
        </output>
      )}
      {panel && state.manages && <AddPanel state={state} panel={panel} setPanel={setPanel} run={run} />}
      {/* Harnesses (cx-mg91) lists every harness; this card shows the ones you added. Nothing to
          list and no answer yet draws no empty outline. */}
      {(state.status === "ready" || added.length > 0) && (
        <div className="rows" data-agent-harnesses>
          {added.length === 0 && <p className="my-2 px-3 text-muted">{t("settingsPage.agents.empty")}</p>}
          {added.map((row) => (
            <HarnessRow key={row.id} row={row} doctor={state.doctor[row.id]} manages={state.manages} run={run} />
          ))}
        </div>
      )}
    </>
  );
}

const SOURCE_KEYS: Record<string, string> = {
  builtIn: "settingsPage.agents.source.builtIn",
  user: "settingsPage.agents.source.user",
  managed: "settingsPage.agents.source.managed",
  cmuxJson: "settingsPage.agents.source.cmuxJson",
  acpx: "settingsPage.agents.source.acpx",
  registry: "settingsPage.agents.source.registry",
};
const KIND_KEYS: Record<string, string> = {
  acp: "settingsPage.agents.kind.acp",
  "claude-stdio": "settingsPage.agents.kind.claudeStdio",
  terminal: "settingsPage.agents.kind.terminal",
};

function HarnessRow({
  row,
  doctor,
  manages,
  run,
}: {
  row: AgentHarnessRow;
  doctor?: AgentDoctorResult;
  manages: boolean;
  run: (gesture: AgentsRun) => Promise<boolean>;
}) {
  const problem = row.unavailable ?? row.probeError;
  const [editing, setEditing] = useState(false);
  return (
    <div className="border-0 border-b border-solid border-edge px-3 py-2 last:border-b-0" data-agent-harness={row.id}>
      <div className="flex items-center gap-2.5">
        <AgentMark agent={row.id} size={16} reserve />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-1.5 text-[13px] text-fg">
            <span className="truncate">{row.name}</span>
            {row.default && (
              <span className="rounded bg-input px-1.5 text-[11px] text-muted">
                {t("settingsPage.agents.defaultBadge")}
              </span>
            )}
          </div>
          <div className="truncate text-[12px] text-muted">
            {[
              row.id,
              t(KIND_KEYS[row.kind] ?? KIND_KEYS.acp!),
              t(SOURCE_KEYS[row.source] ?? SOURCE_KEYS.builtIn!),
            ].join(" · ")}
          </div>
          {problem && <div className="text-[12px] text-warning">{problem}</div>}
        </div>
        {manages && row.kind !== "terminal" && (
          <button
            type="button"
            className="button"
            disabled={doctor?.running}
            onClick={() => void run({ action: "doctor", id: row.id })}
          >
            <StableLabel
              label={doctor?.running ? t("settingsPage.agents.checking") : t("settingsPage.agents.check")}
              alternatives={[t("settingsPage.agents.check"), t("settingsPage.agents.checking")]}
            />
          </button>
        )}
        {manages && row.removable && (
          <button
            type="button"
            className="button"
            aria-expanded={editing}
            data-agent-icon-edit=""
            onClick={() => setEditing(!editing)}
          >
            {t("settingsPage.agents.icon")}
          </button>
        )}
        {manages && row.removable && (
          <button type="button" className="button" onClick={() => void run({ action: "remove", id: row.id })}>
            {t("settingsPage.agents.remove")}
          </button>
        )}
      </div>
      {editing && <IconEditor row={row} run={run} done={() => setEditing(false)} />}
      {doctor && !doctor.running && doctor.steps && <DoctorSteps result={doctor} />}
    </div>
  );
}

/** The bytes of a chosen or dropped PNG or SVG as base64, or null for another kind of file. */
async function iconImage(file: File): Promise<{ data: string; ext: "png" | "svg" } | null> {
  const name = file.name.toLowerCase();
  const ext =
    file.type === "image/svg+xml" || name.endsWith(".svg")
      ? "svg"
      : file.type === "image/png" || name.endsWith(".png")
        ? "png"
        : null;
  if (!ext) return null;
  const bytes = new Uint8Array(await file.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return { data: btoa(binary), ext };
}

/// A user profile's icon (user 12922): type one emoji, an SF Symbol name or an agent; choose or
/// drop a PNG or SVG (acpmux copies it next to the profile); or Automatic. acpmux checks the value
/// and answers why it refuses one.
function IconEditor({
  row,
  run,
  done,
}: {
  row: AgentHarnessRow;
  run: (gesture: AgentsRun) => Promise<boolean>;
  done: () => void;
}) {
  const [value, setValue] = useState(row.icon && !row.icon.includes("/") ? row.icon : "");
  const [over, setOver] = useState(false);
  const file = useRef<HTMLInputElement>(null);
  const apply = async (gesture: AgentsRun) => {
    if (await run(gesture)) done();
  };
  const image = async (chosen: File | undefined) => {
    const picked = chosen ? await iconImage(chosen) : null;
    if (picked) await apply({ action: "icon", id: row.id, ...picked });
  };
  return (
    <div
      className={`mt-2 ml-[26px] rounded-md border border-dashed p-2 ${over ? "border-accent-soft" : "border-edge"}`}
      data-agent-icon-editor={row.id}
      onDragOver={(event) => {
        event.preventDefault();
        setOver(true);
      }}
      onDragLeave={() => setOver(false)}
      onDrop={(event) => {
        event.preventDefault();
        setOver(false);
        void image(event.dataTransfer.files[0]);
      }}
    >
      <form
        className="flex items-center gap-2"
        onSubmit={(event) => {
          event.preventDefault();
          if (value.trim()) void apply({ action: "icon", id: row.id, icon: value.trim() });
        }}
      >
        <input
          className={`${field} flex-1`}
          value={value}
          placeholder={t("settingsPage.agents.icon.placeholder")}
          aria-label={t("settingsPage.agents.icon")}
          onChange={(event) => setValue(event.target.value)}
          // oxlint-disable-next-line jsx-a11y/no-autofocus -- the editor opens on the person's click.
          autoFocus
        />
        <button type="submit" className="button" disabled={!value.trim()}>
          {t("settingsPage.agents.icon.set")}
        </button>
        <button type="button" className="button" onClick={() => file.current?.click()}>
          {t("settingsPage.agents.icon.choose")}
        </button>
        <button
          type="button"
          className="button"
          onClick={() => void apply({ action: "icon", id: row.id, clear: true })}
        >
          {t("settingsPage.agents.icon.auto")}
        </button>
        <input
          ref={file}
          type="file"
          accept=".png,.svg,image/png,image/svg+xml"
          aria-label={t("settingsPage.agents.icon.choose")}
          hidden
          onChange={(event) => void image(event.target.files?.[0])}
        />
      </form>
      <p className="m-0 mt-1.5 text-detail text-muted">{t("settingsPage.agents.icon.help")}</p>
    </div>
  );
}

// The page's own glyphs, as everywhere else in Settings; a skipped step is a dash.
const STEP_ICONS: Record<string, string> = { fail: "xmark", warn: "warning", pass: "check" };

const stepFailed = (step: { ok?: boolean; status?: string }) =>
  step.status ? step.status === "fail" : step.ok === false;

function DoctorSteps({ result }: { result: AgentDoctorResult }) {
  const ok = result.ok ?? !result.steps?.some(stepFailed);
  return (
    <div className="mt-2 ml-[26px] text-[12px]" data-agent-doctor>
      <div className={ok ? "text-fg" : "text-danger"}>
        {ok ? t("settingsPage.agents.works") : t("settingsPage.agents.failed")}
      </div>
      <ol className="m-0 mt-1 list-none p-0">
        {result.steps?.map((step, index) => {
          const status = step.status ?? (step.ok === false ? "fail" : "pass");
          return (
            <li key={`${index}-${step.name}`} className="flex gap-1.5 py-0.5" data-step-status={status}>
              <span
                aria-hidden="true"
                className={`inline-flex w-4 flex-none justify-center ${status === "fail" ? "text-danger" : status === "warn" ? "text-warning" : "text-muted"}`}
              >
                {status === "skip" ? "–" : <Icon name={STEP_ICONS[status] ?? "check"} />}
              </span>
              <span className="min-w-0">
                <span className="text-fg">{step.name}</span>
                {step.detail && <span className="text-muted"> · {step.detail}</span>}
                {step.fix && <span className="block text-muted">{t("settingsPage.agents.fix", step.fix)}</span>}
              </span>
            </li>
          );
        })}
      </ol>
    </div>
  );
}

function AddPanel({
  state,
  panel,
  setPanel,
  run,
}: {
  state: AgentsState;
  panel: Exclude<Panel, null>;
  setPanel: (panel: Panel) => void;
  run: (gesture: AgentsRun) => Promise<boolean>;
}) {
  return (
    <Tabs.Root
      className="mb-3 rounded-lg border border-solid border-edge p-3"
      value={panel}
      onValueChange={(value) => setPanel(value as Exclude<Panel, null>)}
      data-agents-add={panel}
    >
      <Tabs.List className="mb-2 flex items-center gap-1">
        <Tabs.Tab
          value="registry"
          className="cursor-default rounded-md border-0 bg-transparent px-2.5 py-1 font-[inherit] text-control text-muted hover:text-fg data-[active]:bg-accent-soft data-[active]:text-fg"
        >
          {t("settingsPage.agents.tabRegistry")}
        </Tabs.Tab>
        <Tabs.Tab
          value="custom"
          className="cursor-default rounded-md border-0 bg-transparent px-2.5 py-1 font-[inherit] text-control text-muted hover:text-fg data-[active]:bg-accent-soft data-[active]:text-fg"
        >
          {t("settingsPage.agents.tabCustom")}
        </Tabs.Tab>
        <span className="flex-1" />
        <button type="button" className="button" onClick={() => setPanel(null)}>
          {t("settingsPage.agents.cancel")}
        </button>
      </Tabs.List>
      <Tabs.Panel value="registry">
        <RegistryList state={state} run={run} />
      </Tabs.Panel>
      <Tabs.Panel value="custom">
        <CustomForm run={run} done={() => setPanel(null)} />
      </Tabs.Panel>
    </Tabs.Root>
  );
}

function RegistryList({ state, run }: { state: AgentsState; run: (gesture: AgentsRun) => Promise<boolean> }) {
  const [loading, setLoading] = useState(false);
  const asked = useRef(false);
  const load = useCallback(
    async (refresh: boolean) => {
      setLoading(true);
      await run({ action: "registry", refresh });
      setLoading(false);
    },
    [run],
  );
  // The first draw of the tab reads the cached registry (a callback ref, once per mount).
  const opened = useCallback(
    (node: HTMLDivElement | null) => {
      if (!node || asked.current || state.registry) return;
      asked.current = true;
      void load(false);
    },
    [load, state.registry],
  );
  const agents = state.registry?.agents ?? [];
  return (
    <div ref={opened} data-agents-registry>
      <div className="mb-1 flex items-center">
        <span className="flex-1 text-[12px] text-muted">
          {loading && !state.registry ? t("settingsPage.agents.registryLoading") : ""}
        </span>
        <button type="button" className="button" disabled={loading} onClick={() => void load(true)}>
          {t("settingsPage.agents.registryRefresh")}
        </button>
      </div>
      {state.registry && agents.length === 0 && (
        <p className="my-1 text-[13px] text-muted">{t("settingsPage.agents.registryEmpty")}</p>
      )}
      <div className="max-h-[320px] overflow-y-auto">
        {agents.map((agent) => (
          <RegistryRow key={agent.id} agent={agent} run={run} />
        ))}
      </div>
    </div>
  );
}

const LAUNCH_KEYS: Record<string, string> = {
  path: "settingsPage.agents.launch.path",
  npx: "settingsPage.agents.launch.npx",
  uvx: "settingsPage.agents.launch.uvx",
  none: "settingsPage.agents.launch.none",
};

function RegistryRow({ agent, run }: { agent: AgentRegistryAgent; run: (gesture: AgentsRun) => Promise<boolean> }) {
  const [busy, setBusy] = useState(false);
  const added = agent.harnessId !== undefined;
  return (
    <div className="flex items-center gap-2.5 py-1.5" data-registry-agent={agent.id}>
      <AgentMark agent={agent.harnessId ?? agent.id} size={18} />
      <div className="min-w-0 flex-1">
        <div className="truncate text-[13px] text-fg">
          {agent.name}
          {agent.version && <span className="text-muted"> {agent.version}</span>}
        </div>
        <div className="truncate text-[12px] text-muted">
          {[agent.description, t(LAUNCH_KEYS[agent.launch] ?? LAUNCH_KEYS.none!)].filter(Boolean).join(" · ")}
        </div>
      </div>
      <button
        type="button"
        className="button"
        disabled={added || busy || agent.launch === "none"}
        onClick={async () => {
          setBusy(true);
          await run({ action: "add", registry: agent.id });
          setBusy(false);
        }}
      >
        <StableLabel
          label={added ? t("settingsPage.agents.added") : t("settingsPage.agents.addButton")}
          alternatives={[t("settingsPage.agents.addButton"), t("settingsPage.agents.added")]}
        />
      </button>
    </div>
  );
}

/** Splits a typed argument line like a shell does for plain words and quotes. */
export function argumentWords(line: string): string[] {
  const words: string[] = [];
  let current = "";
  let quote: string | null = null;
  let started = false;
  for (const char of line) {
    if (quote) {
      if (char === quote) quote = null;
      else current += char;
    } else if (char === '"' || char === "'") {
      quote = char;
      started = true;
    } else if (/\s/.test(char)) {
      if (started || current) words.push(current);
      current = "";
      started = false;
    } else current += char;
  }
  if (started || current) words.push(current);
  return words;
}

function CustomForm({ run, done }: { run: (gesture: AgentsRun) => Promise<boolean>; done: () => void }) {
  const [name, setName] = useState("");
  const [command, setCommand] = useState("");
  const [args, setArgs] = useState("");
  const [protocol, setProtocol] = useState<"acp" | "terminal">("acp");
  const [secrets, setSecrets] = useState("");
  const [busy, setBusy] = useState(false);
  const label = "mb-0.5 block text-[12px] text-muted";
  return (
    <form
      className="grid grid-cols-2 gap-x-3 gap-y-2"
      data-agents-custom
      onSubmit={async (event) => {
        event.preventDefault();
        if (!command.trim()) return;
        setBusy(true);
        const ok = await run({
          action: "add",
          command: command.trim(),
          displayName: name.trim() || undefined,
          args: argumentWords(args),
          protocol,
          envKeys: secrets
            .split(",")
            .map((key) => key.trim())
            .filter(Boolean),
        });
        setBusy(false);
        if (ok) done();
      }}
    >
      <label className="col-span-1">
        <span className={label}>{t("settingsPage.agents.name")}</span>
        <input
          aria-label={t("settingsPage.agents.name")}
          className={field}
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
      </label>
      <label className="col-span-1">
        <span className={label}>{t("settingsPage.agents.protocol")}</span>
        <select
          aria-label={t("settingsPage.agents.protocol")}
          className={field}
          value={protocol}
          onChange={(event) => setProtocol(event.target.value as "acp" | "terminal")}
        >
          <option value="acp">{t("settingsPage.agents.protocolAcp")}</option>
          <option value="terminal">{t("settingsPage.agents.protocolTerminal")}</option>
        </select>
      </label>
      <label className="col-span-1">
        <span className={label}>{t("settingsPage.agents.command")}</span>
        <input
          aria-label={t("settingsPage.agents.command")}
          className={`${field} font-mono`}
          value={command}
          required
          spellCheck={false}
          onChange={(event) => setCommand(event.target.value)}
        />
      </label>
      <label className="col-span-1">
        <span className={label}>{t("settingsPage.agents.args")}</span>
        <input
          aria-label={t("settingsPage.agents.args")}
          className={`${field} font-mono`}
          value={args}
          spellCheck={false}
          onChange={(event) => setArgs(event.target.value)}
        />
      </label>
      <label className="col-span-2">
        <span className={label}>{t("settingsPage.agents.secrets")}</span>
        <input
          aria-label={t("settingsPage.agents.secrets")}
          className={`${field} font-mono`}
          value={secrets}
          spellCheck={false}
          onChange={(event) => setSecrets(event.target.value)}
        />
        <span className="mt-0.5 block text-[11px] text-soft">{t("settingsPage.agents.secretsHelp")}</span>
      </label>
      <div className="col-span-2 flex justify-end">
        <button type="submit" className="button" disabled={busy || !command.trim()}>
          {t("settingsPage.agents.addButton")}
        </button>
      </div>
    </form>
  );
}
