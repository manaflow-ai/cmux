import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.api" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/api"),
  };
}

function Cmd({
  name,
  desc,
  cli,
  socket,
}: {
  name: string;
  desc: string;
  cli: string;
  socket: string;
}) {
  return (
    <div className="mb-6">
      <h4>{name}</h4>
      <p>{desc}</p>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <CodeBlock title="CLI" lang="bash">{cli}</CodeBlock>
        <CodeBlock title="Socket" lang="json">{socket}</CodeBlock>
      </div>
    </div>
  );
}

export default function ApiPage() {
  const t = useTranslations("docs.api");

  return (
    <>
      <DocsSchema namespace="docs.api" path="/docs/api" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="socket">{t("socket")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("buildHeader")}</th>
            <th>{t("pathHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("release")}</td>
            <td>
              <code>/tmp/cmux.sock</code>
            </td>
          </tr>
          <tr>
            <td>{t("debug")}</td>
            <td>
              <code>/tmp/cmux-debug.sock</code>
            </td>
          </tr>
          <tr>
            <td>{t("taggedDebug")}</td>
            <td>
              <code>/tmp/cmux-debug-&lt;tag&gt;.sock</code>
            </td>
          </tr>
        </tbody>
      </table>
      <p>{t("socketOverride")}</p>
      <CodeBlock lang="json">{`{"id":"req-1","method":"workspace.list","params":{}}
// Response:
{"id":"req-1","ok":true,"result":{"workspaces":[...]}}`}</CodeBlock>
      <Callout>
        {t.rich("socketCallout", {
          legacy: (chunks) => <code>{chunks}</code>,
        })}
      </Callout>

      <DocsHeading level={2} id="access-modes">{t("accessModes")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("modeHeader")}</th>
            <th>{t("descriptionHeader")}</th>
            <th>{t("howToEnableHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <strong>Off</strong>
            </td>
            <td>{t("offMode")}</td>
            <td>{t("offEnable")}</td>
          </tr>
          <tr>
            <td>
              <strong>cmux processes only</strong>
            </td>
            <td>{t("cmuxOnlyMode")}</td>
            <td>{t("cmuxOnlyEnable")}</td>
          </tr>
          <tr>
            <td>
              <strong>allowAll</strong>
            </td>
            <td>{t("allowAllMode")}</td>
            <td>{t("allowAllEnable")}</td>
          </tr>
        </tbody>
      </table>
      <Callout type="warn">
        {t("accessCallout")}
      </Callout>

      <DocsHeading level={2} id="cli-options">{t("cliOptions")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("flagHeader")}</th>
            <th>{t("descriptionHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <code>--socket PATH</code>
            </td>
            <td>{t("customSocketPath")}</td>
          </tr>
          <tr>
            <td>
              <code>--json</code>
            </td>
            <td>{t("outputJson")}</td>
          </tr>
          <tr>
            <td>
              <code>--window ID</code>
            </td>
            <td>{t("targetWindow")}</td>
          </tr>
          <tr>
            <td>
              <code>--workspace ID</code>
            </td>
            <td>{t("targetWorkspace")}</td>
          </tr>
          <tr>
            <td>
              <code>--surface ID</code>
            </td>
            <td>{t("targetSurface")}</td>
          </tr>
          <tr>
            <td>
              <code>--id-format refs|uuids|both</code>
            </td>
            <td>{t("idFormat")}</td>
          </tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="workspace-commands">{t("workspaceCommands")}</DocsHeading>

      <Cmd
        name="list-workspaces"
        desc={t("listWorkspacesDesc")}
        cli={`cmux list-workspaces
cmux list-workspaces --json`}
        socket={`{"id":"ws-list","method":"workspace.list","params":{}}`}
      />
      <Cmd
        name="new-workspace"
        desc={t("newWorkspaceDesc")}
        cli={`cmux new-workspace`}
        socket={`{"id":"ws-new","method":"workspace.create","params":{}}`}
      />
      <Cmd
        name="select-workspace"
        desc={t("selectWorkspaceDesc")}
        cli={`cmux select-workspace --workspace <id>`}
        socket={`{"id":"ws-select","method":"workspace.select","params":{"workspace_id":"<id>"}}`}
      />
      <Cmd
        name="current-workspace"
        desc={t("currentWorkspaceDesc")}
        cli={`cmux current-workspace
cmux current-workspace --json`}
        socket={`{"id":"ws-current","method":"workspace.current","params":{}}`}
      />
      <Cmd
        name="close-workspace"
        desc={t("closeWorkspaceDesc")}
        cli={`cmux close-workspace --workspace <id>`}
        socket={`{"id":"ws-close","method":"workspace.close","params":{"workspace_id":"<id>"}}`}
      />

      <DocsHeading level={2} id="split-commands">{t("splitCommands")}</DocsHeading>

      <Cmd
        name="new-split"
        desc={t("newSplitDesc")}
        cli={`cmux new-split right
cmux new-split down`}
        socket={`{"id":"split-new","method":"surface.split","params":{"direction":"right"}}`}
      />
      <Cmd
        name="list-pane-surfaces"
        desc={t("listPaneSurfacesDesc")}
        cli={`cmux list-pane-surfaces
cmux list-pane-surfaces --json`}
        socket={`{"id":"pane-surfaces","method":"pane.surfaces","params":{}}`}
      />
      <Cmd
        name="focus-panel"
        desc={t("focusSurfaceDesc")}
        cli={`cmux focus-panel --panel <id>`}
        socket={`{"id":"surface-focus","method":"surface.focus","params":{"surface_id":"<id>"}}`}
      />

      <DocsHeading level={2} id="input-commands">{t("inputCommands")}</DocsHeading>

      <Cmd
        name="send"
        desc={t("sendDesc")}
        cli={`cmux send "echo hello"
cmux send "ls -la\\n"`}
        socket={`{"id":"send-text","method":"surface.send_text","params":{"text":"echo hello\\n"}}`}
      />
      <Cmd
        name="send-key"
        desc={t("sendKeyDesc")}
        cli={`cmux send-key enter`}
        socket={`{"id":"send-key","method":"surface.send_key","params":{"key":"enter"}}`}
      />
      <Cmd
        name="send --surface"
        desc={t("sendSurfaceDesc")}
        cli={`cmux send --surface <id> "command"`}
        socket={`{"id":"send-surface","method":"surface.send_text","params":{"surface_id":"<id>","text":"command"}}`}
      />
      <Cmd
        name="send-key --surface"
        desc={t("sendKeySurfaceDesc")}
        cli={`cmux send-key --surface <id> enter`}
        socket={`{"id":"send-key-surface","method":"surface.send_key","params":{"surface_id":"<id>","key":"enter"}}`}
      />

      <DocsHeading level={2} id="notification-commands">{t("notificationCommands")}</DocsHeading>

      <Cmd
        name="notify"
        desc={t("notifyDesc")}
        cli={`cmux notify --title "Title" --body "Body"
cmux notify --title "T" --subtitle "S" --body "B"`}
        socket={`{"id":"notify","method":"notification.create","params":{"title":"Title","subtitle":"S","body":"Body"}}`}
      />
      <Cmd
        name="list-notifications"
        desc={t("listNotificationsDesc")}
        cli={`cmux list-notifications
cmux list-notifications --json`}
        socket={`{"id":"notif-list","method":"notification.list","params":{}}`}
      />
      <Cmd
        name="clear-notifications"
        desc={t("clearNotificationsDesc")}
        cli={`cmux clear-notifications`}
        socket={`{"id":"notif-clear","method":"notification.clear","params":{}}`}
      />

      <DocsHeading level={2} id="sidebar-metadata">{t("sidebarMetadata")}</DocsHeading>
      <p>{t("sidebarMetadataDesc")}</p>

      <Cmd
        name="set-status"
        desc={t("setStatusDesc")}
        cli={`cmux set-status build "compiling" --icon hammer --color "#ff9500" --priority 80
cmux set-status deploy "v1.2.3" --workspace workspace:2`}
        socket={`set_status build compiling --icon=hammer --color=#ff9500 --priority=80 --tab=<workspace-uuid>`}
      />
      <Cmd
        name="clear-status"
        desc={t("clearStatusDesc")}
        cli={`cmux clear-status build`}
        socket={`clear_status build --tab=<workspace-uuid>`}
      />
      <Cmd
        name="list-status"
        desc={t("listStatusDesc")}
        cli={`cmux list-status`}
        socket={`list_status --tab=<workspace-uuid>`}
      />
      <Cmd
        name="set-progress"
        desc={t("setProgressDesc")}
        cli={`cmux set-progress 0.5 --label "Building..."
cmux set-progress 1.0 --label "Done"`}
        socket={`set_progress 0.5 --label=Building... --tab=<workspace-uuid>`}
      />
      <Cmd
        name="clear-progress"
        desc={t("clearProgressDesc")}
        cli={`cmux clear-progress`}
        socket={`clear_progress --tab=<workspace-uuid>`}
      />
      <Cmd
        name="log"
        desc={t("logDesc")}
        cli={`cmux log "Build started"
cmux log --level error --source build "Compilation failed"
cmux log --level success -- "All 42 tests passed"`}
        socket={`log --level=error --source=build --tab=<workspace-uuid> -- Compilation failed`}
      />
      <Cmd
        name="clear-log"
        desc={t("clearLogDesc")}
        cli={`cmux clear-log`}
        socket={`clear_log --tab=<workspace-uuid>`}
      />
      <Cmd
        name="list-log"
        desc={t("listLogDesc")}
        cli={`cmux list-log
cmux list-log --limit 5`}
        socket={`list_log --limit=5 --tab=<workspace-uuid>`}
      />
      <Cmd
        name="sidebar-state"
        desc={t("sidebarStateDesc")}
        cli={`cmux sidebar-state
cmux sidebar-state --workspace workspace:2`}
        socket={`sidebar_state --tab=<workspace-uuid>`}
      />

      <DocsHeading level={2} id="utility-commands">{t("utilityCommands")}</DocsHeading>

      <Cmd
        name="ping"
        desc={t("pingDesc")}
        cli={`cmux ping`}
        socket={`{"id":"ping","method":"system.ping","params":{}}
// Response: {"id":"ping","ok":true,"result":{"pong":true}}`}
      />
      <Cmd
        name="capabilities"
        desc={t("capabilitiesDesc")}
        cli={`cmux capabilities
cmux capabilities --json`}
        socket={`{"id":"caps","method":"system.capabilities","params":{}}`}
      />
      <Cmd
        name="identify"
        desc={t("identifyDesc")}
        cli={`cmux identify
cmux identify --json`}
        socket={`{"id":"identify","method":"system.identify","params":{}}`}
      />

      <DocsHeading level={2} id="env-variables">{t("envVariables")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("variableHeader")}</th>
            <th>{t("descriptionHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <code>CMUX_SOCKET_PATH</code>
            </td>
            <td>{t("socketPathDesc")}</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_ENABLE</code>
            </td>
            <td>{t("socketEnableDesc")}</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_MODE</code>
            </td>
            <td>{t("socketModeDesc")}</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_WORKSPACE_ID</code>
            </td>
            <td>{t("workspaceIdDesc")}</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SURFACE_ID</code>
            </td>
            <td>{t("surfaceIdDesc")}</td>
          </tr>
          <tr>
            <td>
              <code>TERM_PROGRAM</code>
            </td>
            <td>{t("termProgramDesc")}</td>
          </tr>
          <tr>
            <td>
              <code>TERM</code>
            </td>
            <td>{t("termDesc")}</td>
          </tr>
        </tbody>
      </table>
      <Callout>
        {t("envCallout")}
      </Callout>

      <DocsHeading level={2} id="detecting-cmux">{t("detectingCmux")}</DocsHeading>
      <CodeBlock title="bash" lang="bash">{`# Prefer explicit socket path if set
SOCK="\${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
[ -S "$SOCK" ] && echo "Socket available"

# Check for the CLI
command -v cmux &>/dev/null && echo "cmux available"

# In cmux-managed terminals these are auto-set
[ -n "\${CMUX_WORKSPACE_ID:-}" ] && [ -n "\${CMUX_SURFACE_ID:-}" ] && echo "Inside cmux surface"

# Distinguish from regular Ghostty
[ "$TERM_PROGRAM" = "ghostty" ] && [ -n "\${CMUX_WORKSPACE_ID:-}" ] && echo "In cmux"`}</CodeBlock>

      <DocsHeading level={2} id="examples">{t("examples")}</DocsHeading>

      <DocsHeading level={3} id="python-client">{t("pythonClient")}</DocsHeading>
      <CodeBlock title="python" lang="python">{`import json
import os
import socket

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux.sock")

def rpc(method, params=None, req_id=1):
    payload = {"id": req_id, "method": method, "params": params or {}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload).encode("utf-8") + b"\\n")
        return json.loads(sock.recv(65536).decode("utf-8"))

# List workspaces
print(rpc("workspace.list", req_id="ws"))

# Send notification
print(rpc(
    "notification.create",
    {"title": "Hello", "body": "From Python!"},
    req_id="notify"
))`}</CodeBlock>

      <DocsHeading level={3} id="shell-script">{t("shellScript")}</DocsHeading>
      <CodeBlock title="bash" lang="bash">{`#!/bin/bash
SOCK="\${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"

cmux_cmd() {
    printf "%s\\n" "$1" | nc -U "$SOCK"
}

cmux_cmd '{"id":"ws","method":"workspace.list","params":{}}'
cmux_cmd '{"id":"notify","method":"notification.create","params":{"title":"Done","body":"Task complete"}}'`}</CodeBlock>

      <DocsHeading level={3} id="build-script-notification">{t("buildScriptNotification")}</DocsHeading>
      <CodeBlock title="bash" lang="bash">{`#!/bin/bash
npm run build
if [ $? -eq 0 ]; then
    cmux notify --title "✓ Build Success" --body "Ready to deploy"
else
    cmux notify --title "✗ Build Failed" --body "Check the logs"
fi`}</CodeBlock>
    </>
  );
}
