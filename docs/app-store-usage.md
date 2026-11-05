# Using the cmux App Store

How to find, install, use and remove apps in cmux-next, from the app, the command line and an
agent. The design is in [app-store-platonic-ideal.md](app-store-platonic-ideal.md).

All apps are free. An app gets only the permissions you allow on its consent card. Nothing
installs without your click on that card.

## 1. Open the App Store

In this build the App Store is a preview feature. Turn it on first: Settings > Labs > Preview
features, or `cmux settings set labs.previewFeatures true`.

Then use one of these:

- the **App Store** item at the top of the sidebar;
- the palette (Cmd-Shift-P): type `App Store`;
- the command line: `cmux app store`.

**Discover** lists every app you can install. **Installed** lists your apps, what each app may
do, and their logs. An open App Store updates by itself when an app is installed or removed
somewhere else (the command line, another window).

## 2. The example apps

cmux ships four example apps. Each shows one kind of app.

| App | Id | Kind | What it shows |
| --- | --- | --- | --- |
| Standup | `manaflow-ai/standup` | commands only | three commands (Add Note, List Notes, Clear Notes) in the palette, the CLI and MCP; no UI |
| cmux Docs | `manaflow-ai/cmux-docs` | web app | the cmux docs in a sidebar item that opens as a tab; the whole app is its manifest |
| Quick Links | `manaflow-ai/quick-links` | declarative scene | your links as a sidebar section and a pane, drawn natively by cmux |
| Hello Deploy | `manaflow-ai/hello-deploy` | install = deploy + pin | a small web server that runs on your own machine or your cmux Cloud machine and opens as a pane |

The sources are in [samples/apps/](../samples/apps). Copy one to start your own app.

## 3. Install an app

### From the App Store

1. Select the app in **Discover**.
2. Click **Get**.
3. Read the consent card. It names the permissions the app asks for, from the riskiest
   down. For a deployed app, it also names the machine.
4. Click **Install**. To install nothing, click **Cancel**.

### From the command line

```sh
cmux apps list                    # every app, its tier and its state
cmux apps info manaflow-ai/standup  # the app and the permissions it asks for
cmux apps install manaflow-ai/standup
```

`cmux apps install` shows the same consent card in the cmux window and waits for your answer.
It exits 0 when you confirm. When you decline, it exits 1 with "Nothing changed".

`cmux apps list --installed` shows only your apps. Add `--json` to any of these commands for
JSON output. `cmux apps list` and `cmux apps info` also work without the Mac app, for example on
a Linux server that runs `cmux server`.

### From the palette

Cmd-Shift-P, then **Install App…**, then type the app id.

### From an agent

An agent can list apps and read their details, and it can run the commands of an installed
app. It cannot install an app. When an agent runs `cmux apps install`, you get the consent card
and you decide.

## 4. Use an app

| Kind | How |
| --- | --- |
| commands | Cmd-Shift-P and type the command (`Standup: Add Note`). From the CLI: `cmux apps run manaflow-ai/standup manaflow_ai.standup.add --args '{"text":"shipped the store"}'`. Agents get the commands as MCP tools. |
| web app | click its item in the sidebar, or Cmd-Shift-P **Open cmux Docs**. It opens as a browser tab in your workspace. |
| scene app | its section shows in the sidebar; its item opens the pane. Change the links in Settings > Apps > Quick Links. |
| deployed app | see section 5. |

Every way to open an app uses one rule. A scene page opens as a tab. A web app opens its
https address in a browser tab. A deployed app opens its running instance. A command-only app
has nothing to open.

## 5. Install = deploy + pin (your own machine or cmux Cloud)

An app with a `deploy` block in its manifest runs a server: a container on a machine that you
pick. Its pane in cmux shows that server. The same install works on two kinds of machine. The
listing's **Runs on** section, and `cmux apps info <app>`, name the kinds of machine the app
accepts.

### A machine you host yourself (no cmux Cloud needed)

This is the enterprise path. Use any Linux machine with Docker or Podman that you can reach
with SSH: your own VM, a server, or a machine on your tailnet.

```sh
cmux apps install manaflow-ai/hello-deploy --deploy self-hosted:ops@build-01.corp
```

The `self-hosted:` value is an SSH destination: `user@host`, a `Host` alias from your
`~/.ssh/config`, or a tailnet name with Tailscale SSH. cmux uses your own SSH setup and keeps
no key for the machine. Nothing in this path calls cmux Cloud.

### Your cmux Cloud machine

```sh
cmux cloud list-machines         # find the machine id
cmux apps install manaflow-ai/hello-deploy --deploy cloud-vm:<machine id>
```

### What happens

1. The consent card says "It runs its server on self-hosted:ops@build-01.corp and opens it as
   a pane." Click **Install**.
2. cmux installs the app and starts the container on that machine. The container binds to the
   machine's tailnet address, or to 127.0.0.1 when the machine has none, never to every
   interface. cmux then waits until the app's health path answers.
3. When the server is healthy, App Store > Installed shows "Running on <machine>" under the
   app (and "Starting on <machine>" before), and `cmux apps list --installed --json` shows the
   instance as `running`, with its URL. Open the app from the sidebar or the palette, and its
   pane shows the server.
4. When the server does not start or fails its health check, cmux removes the container and
   undoes the install. The reason is in the app's log (App Store > Installed > Logs).

`cmux apps remove manaflow-ai/hello-deploy` removes the app and its container.

Measured 2026-10-30, with a fleet build of this branch on a self-hosted Linux machine
(cmux-dev-backend-1, Docker 29.7.2, reached over Tailscale SSH):

| Step | Time |
| --- | --- |
| install answers (instance `deploying`) | 8 ms |
| instance `running`, image pull from cold included | 2.46 s |
| health check over the tailnet | 0.10 s (HTTP 200) |
| remove until the container is gone | about 2 s |
| an unreachable host rolls the install back | 0.21 s |

## 6. Remove or hide an app

- Remove: App Store > Installed > **Remove**, or `cmux apps remove <app>`. You confirm on a card.
  The app's storage, permissions and instance are deleted.
- Hide: `cmux apps hide <app>`, or Cmd-Shift-P **Hide App…**. The app stays installed and
  answers its granted commands, but it leaves the sidebar, palette and menus. `cmux apps unhide
  <app>` shows it again.
- First-party apps (Home, Cloud, CodeRouter) can be hidden, but not removed.

## 7. Make your own app

1. Copy an example from [samples/apps/](../samples/apps) to `~/.config/cmux/customize/` (your
   own app, id `local/customize`, installs itself and reloads when you save), or to a folder of
   your own.
2. Edit `cmux-app.v2.json`: the listing, the `scopes` with a reason for each, and what the app
   implements. To deploy, add a `deploy` block:

   ```json
   "implements": { "cmux.pane/1": { "remote": "instance", "title": "My Tool" } },
   "deploy": {
     "server": { "kind": "container", "image": "ghcr.io/acme/my-tool:1.2", "port": 8080, "health": "/healthz" },
     "tenancy": ["user"],
     "targets": ["self-hosted", "cloud-vm"]
   },
   "billing": { "model": "free" }
   ```

3. Scripted apps: write `src/main.ts` against the typed `cmux` global
   (`cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`), then build with
   `bun cmux-tui/crates/cmux-app-host/tools/pack.ts <app folder>`.

The validator refuses these:

- a remote pane without a `deploy` block;
- a paid `billing` model (cmux lists free apps only);
- a `local` deploy target for a third-party app (untrusted servers run on a VM or your own
  machine, never on your Mac);
- an image or health path with shell characters.

## 8. What is not built yet

- **Team installs and shared instances.** Today an install is yours only. Team tenancy, pins
  shared through cloud groups and Use/Operate shares are the next phase.
- **A new Cloud machine per app.** `cloud-vm:` deploys to a machine that you already have. It
  does not create one.
- **Kubernetes.** The `self-hosted` runner uses Docker or Podman on one host. A cluster mode
  comes later.
- **Edge identity headers and egress secrets for instances.** The instance is private: it is
  reachable on your tailnet or on loopback only.
- **`apps_propose_install` and `cmux://suggest` links for agents.** Today an agent's install
  request shows you the consent card directly.
