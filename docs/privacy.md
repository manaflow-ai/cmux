# Privacy: what cmux NEXT sends, and where

This page lists every host the cmux NEXT app names in its code: the Mac app, its daemon (`cmux-tui`), its web
pages (`webviews/`) and the iPhone app (`cmux-next-ios/`). `tests/test_outbound_hosts.py` keeps it exact: CI fails
when code names a host that has no row here, and when a row's host is gone from the code.

## Telemetry

Crash and error reports go to the crash reporting host below, only while anonymous telemetry is on. It is on until
you turn it off, and the `DisableTelemetry` managed policy turns it off for everyone on a managed Mac.

- The Mac and iPhone apps keep the choice in their own preferences (`sendAnonymousTelemetry`). Before a report
  leaves the device, the scrubber (`Packages/Shared/CmuxSentryTelemetry`, `SentryScrubber` and
  `SentryEventScrubber`) removes API keys and tokens, passwords, cookies and session ids, credentials in URLs,
  email addresses and your user name in file paths, from every field of the report: message, exception, stack
  frames, breadcrumbs, context, tags, request and user. `SeededSecretTests` puts known secrets in every field and
  checks that none of them is left in the report as it is sent.
- A `cmux` CLI installed on its own (Linux, npm or PyPI; the copy inside the app sends nothing) sends its daemon's
  panic and memory reports. It reads `app.sendAnonymousTelemetry: false` from `~/.config/cmux/cmux-next.json` (or the
  file `CMUX_NEXT_CONFIG_FILE` names), and also stays off with `DO_NOT_TRACK=1`, `CMUX_TUI_TELEMETRY=off` or `CI` set.
  Before sending, `crash_scrub` runs the same rules as the scrubber above on the panic message, location and
  backtrace, and `seeded_secrets_never_leave_in_a_panic_event` seeds them the same way.

Hang reports go to cmux.com only after you agree to send them, and the app never asks while telemetry is off.

## Hosts

Each row is a host, its kind and what the app sends there. Kinds:

- `connects`: the app opens a connection to it, at the time the last column says.
- `opens`: a page shown only when you open it: a link, a search engine, a sign-in page, a site the address bar
  suggests. What it receives is what any web page you open receives.
- `identifier`: a name the app compares or writes but never fetches, such as an XML namespace or a list of hosting
  domains.
- `example`: a sample or placeholder value; the app does not contact it.
- `not-a-host`: text that only looks like a host name (a file name, an icon name, a string key). Listed so the
  check stays exact.

Not in this list: hosts you type or open yourself (the browser, git remotes, SSH hosts, a self-hosted server or an
API endpoint you configure), hosts an agent you run reaches on its own, and a host the code builds from parts at run
time. Reserved names (`.example`, `.test`, `.invalid`, `localhost`, `example.com`) and IP addresses are skipped.



### The app connects to

| Host | Kind | What for |
|---|---|---|
| `claude.ai` | connects | Claude sign-in and the Claude Code installer, when you install or sign in Claude Code |
| `opencode.ai` | connects | OpenCode's config schema and installer, when you install OpenCode |
| `linear.app` | connects | the Linear integration, only when an agent uses it in your signed-in browser |
| `client-api.linear.app` | connects | the Linear integration, only when an agent uses it in your signed-in browser |
| `cmux-staging.vercel.app` | connects | classic cmux Cloud's staging sign-in, only when staging is chosen |
| `cdn.agentclientprotocol.com` | connects | the public registry of ACP coding agents, read by the daemon |
| `api.anthropic.com` | connects | the Anthropic API, when you use an Anthropic key or sign in a Cloud machine's Claude |
| `home.atlassian.com` | connects | the Jira integration, only when an agent uses it in your signed-in browser |
| `api.bing.com` | connects | search suggestions as you type, when Bing is your search engine |
| `chatgpt.com` | connects | OpenAI's Codex backend, when you use Codex with a ChatGPT sign-in; install script |
| `cdnjs.cloudflare.com` | connects | scripts and styles an agent's rendered page may load |
| `cmux.com` | connects | cmux's website and API: sign-in callback, hang reports (when telemetry is on), billing, docs and deep links |
| `files.cmux.com` | connects | downloads: updates, release notes, art, the cmux CLI |
| `files-next.cmux.com` | connects | downloads for the nightly NEXT channel: appcast and release notes |
| `www.cmux.com` | connects | the same site as cmux.com; deep links and sign-in |
| `html.duckduckgo.com` | connects | web search for an agent's search tool, when an agent searches |
| `github.com` | connects | git, the GitHub CLI and the GitHub API for repos, PRs and Cloud machines; release media |
| `api.github.com` | connects | the GitHub API, through the GitHub CLI or the app, for repos and PRs you open |
| `uploads.github.com` | connects | GitHub uploads, through the GitHub CLI |
| `avatars.githubusercontent.com` | connects | images in GitHub pages and agent replies |
| `camo.githubusercontent.com` | connects | images in GitHub pages and agent replies |
| `private-user-images.githubusercontent.com` | connects | images in GitHub pages and agent replies |
| `raw.githubusercontent.com` | connects | release media reels and raw files linked in agent replies |
| `user-images.githubusercontent.com` | connects | images in GitHub pages and agent replies |
| `gitlab.com` | connects | repositories you add from GitLab |
| `accounts.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser |
| `calendar.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser |
| `docs.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser |
| `drive.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser |
| `mail.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser |
| `suggestqueries.google.com` | connects | search suggestions as you type, when Google is your search engine |
| `drive.usercontent.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser |
| `fonts.googleapis.com` | connects | fonts an agent's rendered page may load |
| `lh3.googleusercontent.com` | connects | images in agent replies |
| `fonts.gstatic.com` | connects | fonts an agent's rendered page may load |
| `www.linkedin.com` | connects | the LinkedIn integration, only when an agent uses it in your signed-in browser |
| `app.notion.com` | connects | the Notion integration, only when an agent uses it in your signed-in browser |
| `api.open-meteo.com` | connects | weather on the new tab page, when shown |
| `geocoding-api.open-meteo.com` | connects | weather on the new tab page, when shown |
| `api.openai.com` | connects | the OpenAI API: voice calls on iPhone, and when you use an OpenAI key |
| `app.slack.com` | connects | the Slack integration, only when an agent uses it in your signed-in browser |
| `api.stack-auth.com` | connects | the sign-in service |
| `uniichat.com` | connects | the hosted UniiChat agent, only when you start it |
| `unpkg.com` | connects | scripts and styles an agent's rendered page may load |
| `chatmux.dev` | connects | cmux's chat relay API, for chatmux sessions |
| `api.chatmux.dev` | connects | cmux's chat relay API, for chatmux sessions |
| `api-staging.chatmux.dev` | connects | cmux's chat relay API on staging, only when chosen |
| `preview.chatmux.dev` | connects | preview pages of a chatmux session |
| `cmux.dev` | connects | cmux Cloud host name check; machine and preview URLs under it |
| `cloud-api.cmux.dev` | connects | cmux Cloud API: machines, accounts, sign-in (production) |
| `cloud-api-staging.cmux.dev` | connects | cmux Cloud API on staging, only in development builds or when chosen |
| `mobile-api.cmux.dev` | connects | the iPhone pairing API (production) |
| `presence.cmux.dev` | connects | update channel push: tells the app a new build is out |
| `share.cmux.dev` | connects | shared workspace links (production) |
| `share-dev.cmux.dev` | connects | shared workspace links in development builds |
| `share-staging.cmux.dev` | connects | shared workspace links on staging, only when chosen |
| `vm.cmux.dev` | connects | cmux Cloud machine API (production) |
| `vm-staging.cmux.dev` | connects | cmux Cloud machine API on staging, only when chosen |
| `herdr.dev` | connects | the agent-detection catalog, read by the daemon |
| `cmux-api-development.debussy.workers.dev` | connects | cmux API in development builds |
| `cmux-api-staging.debussy.workers.dev` | connects | cmux API on staging, only when chosen |
| `cmux-device-hub.debussy.workers.dev` | connects | the device hub: pairing and screen sharing between your devices (production) |
| `cmux-device-hub-dev.debussy.workers.dev` | connects | the device hub in development builds |
| `cmux-mobile-api-dev.debussy.workers.dev` | connects | the iPhone pairing API in development builds |
| `cmux-platform-development.debussy.workers.dev` | connects | cmux Cloud platform API in development builds |
| `cmux-platform-production.debussy.workers.dev` | connects | cmux Cloud services on our hosting provider (production): platform API |
| `cmux-platform-staging.debussy.workers.dev` | connects | cmux Cloud platform API on staging, only when chosen |
| `cmux-v2.debussy.workers.dev` | connects | the iPhone app's host API (production) |
| `cmux-v2-development.debussy.workers.dev` | connects | the iPhone app's host API in development builds |
| `cmux-v2-staging.debussy.workers.dev` | connects | the iPhone app's host API on staging, only when chosen |
| `cmux-vnc-signal.debussy.workers.dev` | connects | screen sharing signaling between your devices |
| `api.artic.edu` | connects | museum art for backgrounds, when you search for art |
| `www.artic.edu` | connects | museum art for backgrounds, when you search for art |
| `o4507547940749312.ingest.us.sentry.io` | connects | crash and error reports, scrubbed (below), only when telemetry is on |
| `cdn.jsdelivr.net` | connects | scripts and styles an agent's rendered page may load |
| `cmux-lawrences-mac-mini.tail137216.ts.net` | connects | a team machine's model router, only on a cmux team member's tailnet; nobody else can reach it |
| `openaccess-api.clevelandart.org` | connects | museum art for backgrounds, when you search for art |
| `openaccess-cdn.clevelandart.org` | connects | museum art for backgrounds, when you search for art |
| `registry.npmjs.org` | connects | checks for a newer cmux CLI when installed with npm; npm packages agents install |
| `ciscobinary.openh264.org` | connects | the OpenH264 video codec, downloaded once on Linux for screen sharing |
| `pypi.org` | connects | checks for a newer cmux CLI when installed with pip |
| `commons.wikimedia.org` | connects | museum art for backgrounds, when you search for art |
| `thumb.wikimedia.org` | connects | museum art for backgrounds, when you search for art |
| `upload.wikimedia.org` | connects | museum art for backgrounds, when you search for art |
| `formulae.brew.sh` | connects | checks for a newer cmux CLI when installed with Homebrew |
| `www.notion.so` | connects | the Notion integration, only when an agent uses it in your signed-in browser |

### Pages the app opens when you ask

| Host | Kind | What for |
|---|---|---|
| `lmstudio.ai` | opens | a provider's download page, opened from Settings |
| `console.mistral.ai` | opens | a page to get an API key, opened from Settings |
| `openrouter.ai` | opens | a page to get an API key, opened from Settings |
| `console.x.ai` | opens | a page to get an API key, opened from Settings |
| `airbnb.com` | opens | a site the address bar suggests before it is in your history |
| `amazon.com` | opens | a site the address bar suggests before it is in your history |
| `console.aws.amazon.com` | opens | a page to get an API key, opened from Settings |
| `anthropic.com` | opens | a site the address bar suggests; also an Anthropic host name the app recognizes |
| `auth.anthropic.com` | opens | Anthropic sign-in pages, opened when you sign an agent in |
| `console.anthropic.com` | opens | Anthropic sign-in pages, opened when you sign an agent in |
| `docs.anthropic.com` | opens | setup docs for an agent, opened from onboarding |
| `apple.com` | opens | a site the address bar suggests before it is in your history |
| `developer.apple.com` | opens | a site the address bar suggests before it is in your history |
| `www.baidu.com` | opens | a search engine, when you search with it |
| `bbc.com` | opens | a site the address bar suggests before it is in your history |
| `bing.com` | opens | a site the address bar suggests before it is in your history |
| `www.bing.com` | opens | a search engine, when you search with it |
| `booking.com` | opens | a site the address bar suggests before it is in your history |
| `search.brave.com` | opens | a search engine, when you search with it |
| `claude.com` | opens | Anthropic sign-in pages, opened when you sign an agent in |
| `platform.claude.com` | opens | Anthropic sign-in pages, opened when you sign an agent in |
| `cnn.com` | opens | a site the address bar suggests before it is in your history |
| `platform.deepseek.com` | opens | a page to get an API key, opened from Settings |
| `discord.com` | opens | a site the address bar suggests before it is in your history |
| `duckduckgo.com` | opens | a search engine, when you search with it |
| `ebay.com` | opens | a site the address bar suggests before it is in your history |
| `espn.com` | opens | a site the address bar suggests before it is in your history |
| `etsy.com` | opens | a site the address bar suggests before it is in your history |
| `facebook.com` | opens | a site the address bar suggests before it is in your history |
| `figma.com` | opens | a site the address bar suggests before it is in your history |
| `cli.github.com` | opens | the GitHub CLI's page, named in an error message |
| `gmail.com` | opens | a site the address bar suggests before it is in your history |
| `google.com` | opens | a site the address bar suggests; also matched in an extension's update URL |
| `aistudio.google.com` | opens | a page to get an API key, opened from Settings |
| `chromewebstore.google.com` | opens | the Chrome Web Store, opened from browser extension settings |
| `console.cloud.google.com` | opens | a page to get an API key, opened from Settings |
| `maps.google.com` | opens | a site the address bar suggests before it is in your history |
| `www.google.com` | opens | a search engine, when you search with it |
| `console.groq.com` | opens | a page to get an API key, opened from Settings |
| `imdb.com` | opens | a site the address bar suggests before it is in your history |
| `instagram.com` | opens | a site the address bar suggests before it is in your history |
| `kagi.com` | opens | a search engine, when you search with it |
| `linkedin.com` | opens | a site the address bar suggests before it is in your history |
| `medium.com` | opens | a site the address bar suggests before it is in your history |
| `microsoft.com` | opens | a site the address bar suggests before it is in your history |
| `netflix.com` | opens | a site the address bar suggests before it is in your history |
| `npmjs.com` | opens | a site the address bar suggests before it is in your history |
| `nytimes.com` | opens | a site the address bar suggests before it is in your history |
| `ollama.com` | opens | a provider's download page, opened from Settings |
| `openai.com` | opens | a site the address bar suggests before it is in your history |
| `auth.openai.com` | opens | OpenAI sign-in, opened when you sign Codex in |
| `developers.openai.com` | opens | setup docs for an agent, opened from onboarding |
| `platform.openai.com` | opens | a page to get an API key, opened from Settings |
| `www.qwant.com` | opens | a search engine, when you search with it |
| `reddit.com` | opens | a site the address bar suggests before it is in your history |
| `slack.com` | opens | a site the address bar suggests before it is in your history |
| `spotify.com` | opens | a site the address bar suggests before it is in your history |
| `stackoverflow.com` | opens | a site the address bar suggests before it is in your history |
| `substack.com` | opens | a site the address bar suggests before it is in your history |
| `tailscale.com` | opens | a Tailscale page, opened when you add a device |
| `login.tailscale.com` | opens | a Tailscale page, opened when you add a device |
| `twitter.com` | opens | a site the address bar suggests before it is in your history |
| `vercel.com` | opens | a site the address bar suggests; also a docs host an agent catalog entry may link to |
| `x.com` | opens | cmux on X, a link in Settings |
| `search.yahoo.com` | opens | a search engine, when you search with it |
| `news.ycombinator.com` | opens | a site the address bar suggests before it is in your history |
| `youtube.com` | opens | a site the address bar suggests; also used to find captions in a page you have open |
| `www.youtube.com` | opens | a search engine, when you search with it |
| `discord.gg` | opens | cmux's Discord, a link in Settings |
| `crates.io` | opens | a site the address bar suggests before it is in your history |
| `www.ecosia.org` | opens | a search engine, when you search with it |
| `developer.mozilla.org` | opens | a site the address bar suggests before it is in your history |
| `wikipedia.org` | opens | a site the address bar suggests; also a search keyword's site |
| `en.wikipedia.org` | opens | a search engine, when you search with it |
| `notion.so` | opens | a site the address bar suggests before it is in your history |
| `twitch.tv` | opens | a site the address bar suggests before it is in your history |

### Names the app never contacts

| Host | Kind | What for |
|---|---|---|
| `x.ai` | identifier | an xAI tool method name, not a host |
| `netlify.app` | identifier | a shared hosting domain, so sites under it are told apart |
| `ngrok-free.app` | identifier | a shared hosting domain, so sites under it are told apart |
| `vercel.app` | identifier | a shared hosting domain, so sites under it are told apart |
| `web.app` | identifier | a shared hosting domain, so sites under it are told apart |
| `hf.co` | identifier | a git host name, so it is not shown as one of your computers |
| `huggingface.co` | identifier | a git host name, so it is not shown as one of your computers |
| `repl.co` | identifier | a shared hosting domain, so sites under it are told apart |
| `manaflow.ai` | identifier | an email domain of the cmux team: an account under it gets the team's verbose connectivity diagnostics; nothing is sent to it |
| `amazonaws.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `s3.amazonaws.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `www.apple.com` | identifier | an XML or SVG namespace, never fetched |
| `appspot.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `ssh.dev.azure.com` | identifier | a git host name, so it is not shown as one of your computers |
| `blogspot.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `docs.claude.com` | identifier | a docs host an agent catalog entry may link to |
| `firebaseapp.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `ghe.com` | identifier | GitHub Enterprise host names the GitHub CLI check recognizes |
| `gist.github.com` | identifier | a git host name, so it is not shown as one of your computers |
| `ssh.github.com` | identifier | a git host name, so it is not shown as one of your computers |
| `www.github.com` | identifier | a GitHub host name the app recognizes |
| `altssh.gitlab.com` | identifier | a git host name, so it is not shown as one of your computers |
| `herokuapp.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `link.com` | identifier | a checkout host name the app recognizes |
| `myshopify.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `onrender.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `stripe.com` | identifier | a checkout host name the app recognizes |
| `trycloudflare.com` | identifier | a shared hosting domain, so sites under it are told apart |
| `vs-ssh.visualstudio.com` | identifier | a git host name, so it is not shown as one of your computers |
| `m.youtube.com` | identifier | YouTube host names, to find captions in a page you have open |
| `fly.dev` | identifier | a shared hosting domain, so sites under it are told apart |
| `pages.dev` | identifier | a shared hosting domain, so sites under it are told apart |
| `workers.dev` | identifier | a shared hosting domain, so sites under it are told apart |
| `github.io` | identifier | a shared hosting domain, so sites under it are told apart |
| `gitlab.io` | identifier | a shared hosting domain, so sites under it are told apart |
| `ngrok.io` | identifier | a shared hosting domain, so sites under it are told apart |
| `ac.jp` | identifier | a public suffix, so sites under it are told apart |
| `go.jp` | identifier | a public suffix, so sites under it are told apart |
| `ne.jp` | identifier | a public suffix, so sites under it are told apart |
| `or.jp` | identifier | a public suffix, so sites under it are told apart |
| `or.kr` | identifier | a public suffix, so sites under it are told apart |
| `azurewebsites.net` | identifier | a shared hosting domain, so sites under it are told apart |
| `cloudfront.net` | identifier | a shared hosting domain, so sites under it are told apart |
| `govt.nz` | identifier | a public suffix, so sites under it are told apart |
| `bitbucket.org` | identifier | a known code forge, to read a module's source URL |
| `altssh.bitbucket.org` | identifier | a git host name, so it is not shown as one of your computers |
| `codeberg.org` | identifier | a known code forge, to read a module's source URL |
| `www.ietf.org` | identifier | an RTP header extension id, never fetched |
| `json-schema.org` | identifier | a JSON schema id, never fetched |
| `www.w3.org` | identifier | an XML or SVG namespace, never fetched |
| `freestyle.sh` | identifier | a cloud host name the app recognizes |
| `ac.uk` | identifier | a public suffix, so sites under it are told apart |
| `ltd.uk` | identifier | a public suffix, so sites under it are told apart |
| `me.uk` | identifier | a public suffix, so sites under it are told apart |
| `plc.uk` | identifier | a public suffix, so sites under it are told apart |

### Samples and placeholders

| Host | Kind | What for |
|---|---|---|
| `docs.github.com` | example | a sample error text |
| `api.stripe.com` | example | an example in a tool description |
| `github.com.evil` | example | a value in a self-check |
| `webauthn.io` | example | a sample saved passkey |
| `cdn-example.net` | example | a sample in a dialog |
| `mini.tail1234.ts.net` | example | a placeholder in a settings field |
| `r.org` | example | a value in a self-check |

### Text that looks like a host name

| Host | Kind | What for |
|---|---|---|
| `task.ai` | not-a-host | a symbol or icon name |
| `argument.app` | not-a-host | a localized string key |
| `cmux.app` | not-a-host | a file name |
| `cmux-ios-com.cmux.app` | not-a-host | a URL scheme or bundle id |
| `debug.crash.app` | not-a-host | a method, area or resource kind name |
| `arrow.down.app` | not-a-host | a symbol or icon name |
| `arrow.up.forward.app` | not-a-host | a symbol or icon name |
| `host.app` | not-a-host | a file name |
| `argument.phone.app` | not-a-host | a localized string key |
| `plus.app` | not-a-host | a symbol or icon name |
| `resources.role.app` | not-a-host | a localized string key |
| `keybindings.page.source.app` | not-a-host | a localized string key |
| `reading.theme.app` | not-a-host | a localized string key |
| `xmark.app` | not-a-host | a symbol or icon name |
| `updater.channels.ring.dev` | not-a-host | a localized string key |
| `argument.value.dev` | not-a-host | a localized string key |
| `fs.io` | not-a-host | a method, area or resource kind name |
| `keybindings.io` | not-a-host | a method, area or resource kind name |
| `local.io` | not-a-host | a method, area or resource kind name |
| `machine.io` | not-a-host | a method, area or resource kind name |
| `cloud.machine.io` | not-a-host | a method, area or resource kind name |
| `config.ru` | not-a-host | a file name |
| `agent-auth.sh` | not-a-host | a file name |
| `build.sh` | not-a-host | a file name |
| `cmux-debug-cli.sh` | not-a-host | a file name |
| `login.sh` | not-a-host | a file name |
| `web-lint.sh` | not-a-host | a file name |
| `libopenh264-2.6.0-linux-arm64.8.so` | not-a-host | a file name |
| `libopenh264-2.6.0-linux64.8.so` | not-a-host | a file name |
