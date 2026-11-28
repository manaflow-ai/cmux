# Privacy: what cmux NEXT sends, and where

This page lists every host the cmux NEXT app names in its code: the Mac app, its daemon (`cmux-tui`), its web
pages (`webviews/`) and the iPhone app (`cmux-next-ios/`). `tests/test_outbound_hosts.py` keeps it exact: CI fails
when code names a host that has no row here, and when a row's host is gone from the code.

## Telemetry

Crash and error reports go to the crash reporting host below, only while anonymous telemetry is on. It is off until
you turn it on (Settings > Privacy and Security > Send Crash Reports and Analytics, `app.sendAnonymousTelemetry`;
the page asks before it turns it on), and the `DisableTelemetry` managed policy keeps it off for everyone on a
managed Mac. A fresh install starts no crash reporter and no analytics (`FreshInstallSendsNothingTests`).
Team usage sharing (`diagnostics.usageSharing`) is off until your team's admin enables it, you have seen its notice and
acknowledged it (`diagnostics.usageSharingNoticeAck`), and you turned it on.

- The Mac and iPhone apps keep the choice in their own preferences (`sendAnonymousTelemetry`); unset means off.
  On the Mac, the person's own write of the setting sets that preference, and crash reporting reads it at the next
  launch. Reports carry no request URLs: network breadcrumbs and network tracking are off. Before a report
  leaves the device, the scrubber (`Packages/Shared/CmuxSentryTelemetry`, `SentryScrubber` and
  `SentryEventScrubber`) removes API keys and tokens, passwords, cookies and session ids, credentials in URLs,
  email addresses and your user name in file paths, from every field of the report: message, exception, stack
  frames, breadcrumbs, context, tags, request and user. `SeededSecretTests` puts known secrets in every field and
  checks that none of them is left in the report as it is sent.
- A `cmux` CLI installed on its own (Linux, npm or PyPI; the copy inside the app sends nothing) sends its daemon's
  panic and memory reports. It sends only when `app.sendAnonymousTelemetry: true` is set (unset is off); it reads it from `~/.config/cmux/cmux-next.json` (or the
  file `CMUX_NEXT_CONFIG_FILE` names), and also stays off with `DO_NOT_TRACK=1`, `CMUX_TUI_TELEMETRY=off` or `CI` set.
  Before sending, `crash_scrub` runs the same rules as the scrubber above on the panic message, location and
  backtrace, and `seeded_secrets_never_leave_in_a_panic_event` seeds them the same way.

- The Chief (`optchat-chief`, the host behind Home's Chief chat) sends anonymous product events to PostHog
  (`us.i.posthog.com`): turns, subagents, latency, token counts, cost, error classes and activation milestones, as
  closed tokens and numbers. It never sends message, reply, task or report text, tool arguments, error messages,
  paths, URLs or names, and IP geolocation is off. A Chief on this Mac is known only by a random install id; a Cloud
  Chief, which runs on cmux's servers for a signed-in account, sends as that account's user id and team id, like
  the server's own Cloud events. It is off until the person turns it on: `sendAnonymousTelemetry` in the app (the
  running Chief re-reads it every few minutes) or, with no app choice, `app.sendAnonymousTelemetry: true` in
  `cmux-next.json`. These keep it off whatever the setting says: the
  `DisableTelemetry` policy, `DO_NOT_TRACK=1` or `CMUX_CHIEF_ANALYTICS=off`; turning it off deletes the events still
  waiting. Its panics go to the crash reporting host through the app with the location and backtrace only, never
  the panic message. The event list: [chief-product-analytics.md](posthog/chief-product-analytics.md).

Hang reports go to cmux.com only after you agree to send them, and the app never asks while telemetry is off.

## Usage patterns (local only)

Usage patterns are off until you turn on Record Usage Patterns (`diagnostics.usagePatterns`, Settings > Privacy and
Security). They are never sent anywhere: each daemon on the machine (`cmux-tui`, acpmux) keeps one small file of
counters under the state directory's `usage-patterns` folder (`cmux-tui/crates/cmux-usage-patterns`). A counter
names a code-defined family and an identifier the program defines: a command or operation name, a split direction,
a transport, a client kind, a harness, a token kind, or a 12-digit opaque stand-in for a paired machine's id. The
key filter (`clean_key`) refuses anything with a space, quote, `@`, `?`, `=`, `~`, a backslash, `:/` or more than one
`/`, so no prompt, terminal text, URL, file path or title becomes a key. Each family keeps at most 200 keys and the
per-day rollup 90 days. `cmux usage-patterns` and the Agent Stats page show them; `cmux usage-patterns reset`
deletes them.

## Egress gate

For firewalls that allow only listed hosts: [network-requirements.md](network-requirements.md) lists the hosts,
ports and address ranges a client needs for relay and connectivity.

The host list below is checked in CI (`tests/test_outbound_hosts.py`) and at run time. The daemon's Rust makes its
HTTP clients through one egress gate (`cmux-tui/crates/cmux-egress`), whose resolver checks each host before it is
looked up; the Mac and iPhone apps' Swift makes its sessions, WebSockets and network connections through the same
gate's Swift side (`Packages/Shared/CmuxEgress`): in dev and nightly builds a host with no `connects` row is refused and logged (`egress.unlisted host=...
site=...`); a release build logs it. `CMUX_EGRESS=enforce|log|off` overrides the mode. Hosts you configure yourself
(a self-hosted server, an API endpoint, an SSH or git host) pass because you named them; loopback, IP addresses and
reserved names, single-label names and private-network names (`.ts.net`, `.internal`, `.lan`) pass. The gate's
allowlist, `cmux-tui/crates/cmux-egress/hosts.txt`, is the one source: it records each host with what the app sends
there, the Rust gate compiles it in, the Swift gate's list is checked equal to it, and the "The app connects to"
table below is generated from it (`python3 scripts/privacy_hosts_from_gate.py`). CI fails when the table and the
allowlist differ, so this page cannot drift from what the gate lets through.

The gate keeps an audit trail: every connection it sees, allowed or refused, is recorded once per host, caller and
verdict for the life of the process. Set `CMUX_EGRESS_AUDIT=/path/file.jsonl` and each new record is appended there as
one JSON line (`ts`, `host`, `site`, `verdict` = listed, named, session, local or unlisted, `mode`, `refused`). The file
stays on your machine; nothing in it is sent anywhere.

Not every client goes through the gate yet. `tests/test_egress_gate.py` finds every client the code makes by hand
(Rust and Swift); `tests/egress_ungated.json` lists the ones not moved yet, and that list may only shrink. The web
pages' Content Security Policy comes next.

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
API endpoint you configure), hosts an agent you run reaches on its own, and a host made entirely of parts known only
at run time. A host the code builds around a fixed name (`https://${site}.atlassian.net`) is listed with `*` for
each part it fills in. Reserved names (`.example`, `.test`, `.invalid`, `localhost`, `example.com`) and IP addresses are skipped.



### The app connects to

<!-- egress-hosts:begin: generated from cmux-tui/crates/cmux-egress/hosts.txt by python3 scripts/privacy_hosts_from_gate.py; edit hosts.txt, not this table -->

| Host | Kind | What for | Sends | When | Turn it off |
|---|---|---|---|---|---|
| `*.*.wdev.cmux.dev` | connects | a cmux developer's preview stack, only when the iPhone app's backend override names one | the iPhone app's requests to that preview stack | only when the iPhone app's backend override names one | clear the backend override |
| `*.atlassian.net` | connects | the Jira integration: your company's Jira site, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `*.r2.cloudflarestorage.com` | connects | a large chat attachment you upload or open in cmux Cloud: the file's bytes go to cmux's storage bucket through a presigned URL the cmux API made | the attachment file's bytes | when you upload or open a large chat attachment in cmux Cloud | don't attach large files in Cloud chats |
| `accounts.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `ai-gateway.vercel.sh` | connects | the Vercel AI Gateway API, when you add a Vercel AI Gateway key in Settings | your prompts, the files and output the agent sends, and your Vercel AI Gateway key | when an agent uses your Vercel AI Gateway key | remove the Vercel AI Gateway key |
| `aiplatform.googleapis.com` | connects | the Google Vertex AI API, when you add a Google Vertex AI key in Settings or sign a Gemini agent in to Vertex | your prompts, the files and output the agent sends, and your Google Vertex AI key | when an agent uses your Google Vertex AI key | remove the Google Vertex AI key |
| `api-staging.chatmux.dev` | connects | cmux's chat relay API on staging, only when chosen | your chatmux session's messages and your account token | only when you choose staging | release builds use production unless you choose staging |
| `api.*.wdev.cmux.dev` | connects | the API of a cmux developer's preview stack, only when the iPhone app's backend override names one | the iPhone app's API requests and account token | only when the iPhone app's backend override names one | clear the backend override |
| `api.anthropic.com` | connects | the Anthropic API, when you use an Anthropic key or sign in a Cloud machine's Claude | your prompts, the files and output the agent sends, and your Anthropic key | when an agent uses your Anthropic key or sign-in | remove the Anthropic key or sign-in |
| `api.artic.edu` | connects | museum art for backgrounds, when you search for art | your art search words, then image requests | when you search for background art | don't search for art (`appearance.background`) |
| `api.bing.com` | connects | search suggestions as you type, when Bing is your search engine | what you type in the address bar | as you type, when Bing is your search engine | `browser.omnibar.remoteSuggestions` off, or another `browser.searchEngine` |
| `api.cerebras.ai` | connects | the Cerebras API, when you add a Cerebras key in Settings | your prompts, the files and output the agent sends, and your Cerebras key | when an agent uses your Cerebras key | remove the Cerebras key |
| `api.chatmux.dev` | connects | cmux's chat relay API, for chatmux sessions | your chatmux session's messages and your account token | when you use chatmux sessions | don't start a chatmux session |
| `api.cloudflare.com` | connects | the Cloudflare API, only when you run `cmux keys connect cloudflare` or `cmux keys mint` | your Cloudflare token and the key requests you run | only `cmux keys connect cloudflare` or `cmux keys mint` | don't run those commands |
| `api.deepseek.com` | connects | the DeepSeek API, when you add a DeepSeek key in Settings | your prompts, the files and output the agent sends, and your DeepSeek key | when an agent uses your DeepSeek key | remove the DeepSeek key |
| `api.eu.mistral.ai` | connects | the Mistral (EU region) API, when you add a Mistral (EU region) key in Settings | your prompts, the files and output the agent sends, and your Mistral (EU region) key | when an agent uses your Mistral (EU region) key | remove the Mistral (EU region) key |
| `api.fireworks.ai` | connects | the Fireworks AI API, when you add a Fireworks AI key in Settings | your prompts, the files and output the agent sends, and your Fireworks AI key | when an agent uses your Fireworks AI key | remove the Fireworks AI key |
| `api.freestyle.sh` | connects | only `cmux vm pool` (the CI runner pool tool, run by cmux's own CI with its own Freestyle key): lists, starts and pauses the pool's VMs; never run by the app | the CI pool's own requests with cmux CI's credential | only `cmux vm pool`, run by cmux's own CI | the app never runs it |
| `api.github.com` | connects | the GitHub API, through the GitHub CLI or the app, for repos and PRs you open | your GitHub token and the repo, PR and file requests you or an agent make | when you or an agent use git, gh or the app's GitHub views | sign out of GitHub (`gh auth logout`) |
| `api.githubcopilot.com` | connects | GitHub's hosted MCP server, for the GitHub tools an agent on a Cloud machine calls | the agent's GitHub tool calls with your GitHub token | when an agent on a Cloud machine calls a GitHub tool | don't connect GitHub to Cloud machines |
| `api.groq.com` | connects | the Groq API, when you add a Groq key in Settings | your prompts, the files and output the agent sends, and your Groq key | when an agent uses your Groq key | remove the Groq key |
| `api.kimi.ai` | connects | the Kimi Code (global) API, when you add a Kimi Code (global) key in Settings | your prompts, the files and output the agent sends, and your Kimi Code (global) key | when an agent uses your Kimi Code (global) key | remove the Kimi Code (global) key |
| `api.kimi.com` | connects | the Kimi Code (China) API, when you add a Kimi Code (China) key in Settings | your prompts, the files and output the agent sends, and your Kimi Code (China) key | when an agent uses your Kimi Code (China) key | remove the Kimi Code (China) key |
| `api.meta.ai` | connects | the Meta Llama API, when you add a Meta Llama key in Settings | your prompts, the files and output the agent sends, and your Meta Llama key | when an agent uses your Meta Llama key | remove the Meta Llama key |
| `api.minimax.io` | connects | the MiniMax (global) API, when you add a MiniMax (global) key in Settings | your prompts, the files and output the agent sends, and your MiniMax (global) key | when an agent uses your MiniMax (global) key | remove the MiniMax (global) key |
| `api.minimaxi.com` | connects | the MiniMax (China) API, when you add a MiniMax (China) key in Settings | your prompts, the files and output the agent sends, and your MiniMax (China) key | when an agent uses your MiniMax (China) key | remove the MiniMax (China) key |
| `api.mistral.ai` | connects | the Mistral API, when you add a Mistral key in Settings | your prompts, the files and output the agent sends, and your Mistral key | when an agent uses your Mistral key | remove the Mistral key |
| `api.moonshot.ai` | connects | the Moonshot (international) API, when you add a Moonshot (international) key in Settings | your prompts, the files and output the agent sends, and your Moonshot (international) key | when an agent uses your Moonshot (international) key | remove the Moonshot (international) key |
| `api.moonshot.cn` | connects | the Moonshot (mainland China) API, when you add a Moonshot (mainland China) key in Settings | your prompts, the files and output the agent sends, and your Moonshot (mainland China) key | when an agent uses your Moonshot (mainland China) key | remove the Moonshot (mainland China) key |
| `api.morphllm.com` | connects | the Morph API, when you add a Morph key in Settings | your prompts, the files and output the agent sends, and your Morph key | when an agent uses your Morph key | remove the Morph key |
| `api.open-meteo.com` | connects | the clock and weather widget's forecast, only when you install it (a customize template) | your city's coordinates | when the clock and weather widget refreshes | remove the widget (a customize template you installed) |
| `api.openai.com` | connects | the OpenAI API: voice calls on iPhone, and when you use an OpenAI key | your prompts and agent output with your OpenAI key; on iPhone, voice call audio | when an agent uses your OpenAI key, or you start a voice call on iPhone | remove the OpenAI key; don't start voice calls |
| `api.stack-auth.com` | connects | the sign-in service | your sign-in credentials and session token | when you sign in or the app refreshes your session | stay signed out |
| `api.tailscale.com` | connects | the Tailscale API, only when you add a Cloud machine to your tailnet with an OAuth client: the Mac trades the client secret for a single-use key there, so the secret never reaches the machine | your Tailscale OAuth client ID and secret, and the request for a single-use auth key | only when you add a Cloud machine to your tailnet with an OAuth client | don't add Cloud machines to a tailnet with an OAuth client |
| `api.together.ai` | connects | the Together AI API, when you add a Together AI key in Settings (its key page is on the same host) | your prompts, the files and output the agent sends, and your Together AI key | when an agent uses your Together AI key | remove the Together AI key |
| `api.us.mistral.ai` | connects | the Mistral (US region) API, when you add a Mistral (US region) key in Settings | your prompts, the files and output the agent sends, and your Mistral (US region) key | when an agent uses your Mistral (US region) key | remove the Mistral (US region) key |
| `api.x.ai` | connects | the xAI API, when you give an agent an xAI API key | your prompts, the files and output the agent sends, and your xAI key | when an agent uses your xAI key or sign-in | remove the xAI key or sign-in |
| `api.z.ai` | connects | the Z.ai API, when you add a Z.ai key in Settings | your prompts, the files and output the agent sends, and your Z.ai key | when an agent uses your Z.ai key | remove the Z.ai key |
| `app.notion.com` | connects | the Notion integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `app.slack.com` | connects | the Slack integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `auth.kimi.ai` | connects | Kimi's sign-in server (global), when you sign Kimi in with your Kimi account | the sign-in code and your Kimi refresh token, to get a new access token | when you sign Kimi in, and when its access token is renewed | sign Kimi out |
| `auth.kimi.com` | connects | Kimi's sign-in server (China), when you sign Kimi in with your Kimi account | the sign-in code and your Kimi refresh token, to get a new access token | when you sign Kimi in, and when its access token is renewed | sign Kimi out |
| `auth.x.ai` | connects | xAI's sign-in server, when you sign Grok in with your xAI account | the sign-in code and your xAI refresh token, to renew or revoke the access token | when you sign Grok in or out, and when its access token is renewed | sign Grok out |
| `avatars.githubusercontent.com` | connects | images in GitHub pages and agent replies | an image request (your IP address and the image's URL) | when a GitHub page or agent reply you open shows an image | not a setting: it follows what you open |
| `bedrock-mantle.*.api.aws` | connects | the Amazon Bedrock API in the region you pick, when you add a Bedrock key in Settings | your prompts, the files and output the agent sends, and your Bedrock key | when an agent uses your Bedrock key | remove the Bedrock key |
| `bedrock-mantle.us-east-1.api.aws` | connects | the Amazon Bedrock API's default region (us-east-1), when you add a Bedrock key in Settings | your prompts, the files and output the agent sends, and your Bedrock key | when an agent uses your Bedrock key | remove the Bedrock key |
| `calendar.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `camo.githubusercontent.com` | connects | images in GitHub pages and agent replies | an image request (your IP address and the image's URL) | when a GitHub page or agent reply you open shows an image | not a setting: it follows what you open |
| `captive.apple.com` | connects | only for a cmux team account, after a Mac stayed unreachable for 30 s: the iPhone app checks Apple's captive portal page (as iOS does) to tell its own outage from a cmux one | a plain page request, as iOS sends | only for a cmux team account, after a Mac stayed unreachable for 30 s | not a setting: team accounts only |
| `cdn.agentclientprotocol.com` | connects | the public registry of ACP coding agents, read by the daemon | a plain download request, no account data | when the daemon refreshes its catalog | no setting yet |
| `cdn.jsdelivr.net` | connects | scripts and styles an agent's rendered page may load | a file request (your IP address and the file's URL) | when an agent's rendered page loads it | not a setting: it follows the page you open |
| `cdnjs.cloudflare.com` | connects | scripts and styles an agent's rendered page may load | a file request (your IP address and the file's URL) | when an agent's rendered page loads it | not a setting: it follows the page you open |
| `chatgpt.com` | connects | OpenAI's Codex backend, when you use Codex with a ChatGPT sign-in; install script | your prompts and agent output with your ChatGPT sign-in; the installer download | when Codex runs with a ChatGPT sign-in, or you install it | sign Codex out of ChatGPT |
| `chatmux.dev` | connects | cmux's chat relay API, for chatmux sessions | your chatmux session's messages and your account token | when you use chatmux sessions | don't start a chatmux session |
| `ciscobinary.openh264.org` | connects | the OpenH264 video codec, downloaded once on Linux for screen sharing | a codec download request | once on Linux, the first time you share a screen | don't share a screen on Linux |
| `claude.ai` | connects | Claude sign-in and the Claude Code installer, when you install or sign in Claude Code | your Claude sign-in; the installer download | when you install or sign in Claude Code | don't install or sign in Claude Code |
| `client-api.linear.app` | connects | the Linear integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `cloud-api-staging.cmux.dev` | connects | cmux Cloud API on staging, only in development builds or when chosen | your cmux account token and the Cloud requests you make | only when you choose staging | release builds use production unless you choose staging |
| `cloud-api.cmux.dev` | connects | cmux Cloud API: machines, accounts, sign-in (production) | your cmux account token and the Cloud requests you make | when you use cmux Cloud | don't sign in to cmux Cloud |
| `cmux-api-development.debussy.workers.dev` | connects | cmux API in development builds | the app's cmux API requests and account token | development builds only, or when you choose that stack | release builds never connect unless you choose it |
| `cmux-api-preview-*.debussy.workers.dev` | connects | cmux API of one pull request's preview, only when chosen | the app's cmux API requests and account token | only when you choose that pull request's preview | release builds never connect unless you choose it |
| `cmux-api-staging.debussy.workers.dev` | connects | cmux API on staging, only when chosen | the app's cmux API requests and account token | only when you choose staging | release builds use production unless you choose staging |
| `cmux-device-hub-dev.debussy.workers.dev` | connects | the device hub in development builds | device pairing and screen-share messages | development builds only, or when you choose that stack | release builds never connect unless you choose it |
| `cmux-device-hub.debussy.workers.dev` | connects | the device hub: pairing and screen sharing between your devices (production) | device pairing and screen-share messages with your account token | when you pair devices or share a screen | don't pair devices |
| `cmux-mobile-api-dev.debussy.workers.dev` | connects | the iPhone pairing API in development builds | iPhone pairing requests | development builds only, or when you choose that stack | release builds never connect unless you choose it |
| `cmux-platform-development.debussy.workers.dev` | connects | cmux Cloud platform API in development builds | your cmux account token and the Cloud requests you make | development builds only, or when you choose that stack | release builds never connect unless you choose it |
| `cmux-platform-production.debussy.workers.dev` | connects | cmux Cloud services on our hosting provider (production): platform API | your cmux account token and the Cloud requests you make | when you use cmux Cloud | don't sign in to cmux Cloud |
| `cmux-platform-staging.debussy.workers.dev` | connects | cmux Cloud platform API on staging, only when chosen | your cmux account token and the Cloud requests you make | only when you choose staging | release builds use production unless you choose staging |
| `cmux-staging.vercel.app` | connects | classic cmux Cloud's staging sign-in, only when staging is chosen | your sign-in on staging | only when you choose staging | release builds use production unless you choose staging |
| `cmux-vnc-signal.debussy.workers.dev` | connects | screen sharing signaling between your devices | connection setup messages between your devices, no screen content | when you share a screen between your devices | don't share a screen |
| `cmux.com` | connects | cmux's website and API: sign-in callback, hang reports (when telemetry is on), billing, docs and deep links | sign-in callbacks, billing and docs requests; hang reports only with telemetry on | when you sign in, open billing or docs; hang reports when they happen | `app.sendAnonymousTelemetry` off (the default) stops hang reports |
| `cmux.dev` | connects | cmux Cloud host name check; machine and preview URLs under it | your cmux account token and the Cloud requests you make | when you use cmux Cloud | don't sign in to cmux Cloud |
| `codeload.github.com` | connects | a GitHub repository's archive at one commit, when you install an extension from it | an archive download request | when you install an extension from a GitHub repository | don't install extensions from GitHub |
| `commons.wikimedia.org` | connects | museum art for backgrounds, when you search for art | your art search words, then image requests | when you search for background art | don't search for art (`appearance.background`) |
| `compute.googleapis.com` | connects | only `cmux vm pool` (the CI runner pool tool, run by cmux's own CI with its own Google Cloud credential): lists, resumes and suspends the pool's instances by name; never run by the app | the CI pool's own requests with cmux CI's credential | only `cmux vm pool`, run by cmux's own CI | the app never runs it |
| `dashscope-intl.aliyuncs.com` | connects | the Alibaba Model Studio (international) API, when you add a Alibaba Model Studio (international) key in Settings | your prompts, the files and output the agent sends, and your Alibaba Model Studio (international) key | when an agent uses your Alibaba Model Studio (international) key | remove the Alibaba Model Studio (international) key |
| `dashscope-us.aliyuncs.com` | connects | the Alibaba Model Studio (US) API, when you add a Alibaba Model Studio (US) key in Settings | your prompts, the files and output the agent sends, and your Alibaba Model Studio (US) key | when an agent uses your Alibaba Model Studio (US) key | remove the Alibaba Model Studio (US) key |
| `dashscope.aliyuncs.com` | connects | the Alibaba Model Studio (China) API, when you add a Alibaba Model Studio (China) key in Settings | your prompts, the files and output the agent sends, and your Alibaba Model Studio (China) key | when an agent uses your Alibaba Model Studio (China) key | remove the Alibaba Model Studio (China) key |
| `docs.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `drive.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `drive.usercontent.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `files-next.cmux.com` | connects | downloads for the nightly NEXT channel: appcast, release notes and the in-app browser's Chromium runtime | your version and update channel; download requests | nightly NEXT update checks and the browser runtime download | `updates.checkAutomatically` off |
| `files.cmux.com` | connects | downloads: updates, release notes, art, the cmux CLI | your version and update channel; download requests | update checks, and when you download art or the CLI | `updates.checkAutomatically` off |
| `fonts.googleapis.com` | connects | fonts an agent's rendered page may load | a file request (your IP address and the file's URL) | when an agent's rendered page loads it | not a setting: it follows the page you open |
| `fonts.gstatic.com` | connects | fonts an agent's rendered page may load | a file request (your IP address and the file's URL) | when an agent's rendered page loads it | not a setting: it follows the page you open |
| `formulae.brew.sh` | connects | checks for a newer cmux CLI when installed with Homebrew | a version lookup for the cmux CLI | when a Homebrew-installed cmux CLI checks for a newer version | no setting yet |
| `gateway.ai.cloudflare.com` | connects | Cloudflare AI Gateway, at the account and gateway you enter, when you add a Cloudflare AI Gateway key in Settings | your prompts, the files and output the agent sends, and your Cloudflare AI Gateway key | when an agent uses your Cloudflare AI Gateway key | remove the Cloudflare AI Gateway key |
| `generativelanguage.googleapis.com` | connects | the Google AI API, when you give an agent a Google AI API key | your prompts, the files and output the agent sends, and your Google AI key | when an agent uses your Google AI key or sign-in | remove the Google AI key or sign-in |
| `geocoding-api.open-meteo.com` | connects | the clock and weather widget's city search, only when you install it (a customize template) | the city name you search | when you search a city in the clock and weather widget | remove the widget (a customize template you installed) |
| `github.com` | connects | git, the GitHub CLI and the GitHub API for repos, PRs and Cloud machines; release media | your GitHub token and the repo, PR and file requests you or an agent make | when you or an agent use git, gh or the app's GitHub views | sign out of GitHub (`gh auth logout`) |
| `gitlab.com` | connects | repositories you add from GitLab | your git requests and credentials for that repository | when you add or sync a GitLab repository | don't add GitLab repositories |
| `herdr.dev` | connects | the agent-detection catalog, read by the daemon | a plain download request, no account data | when the daemon refreshes its catalog | no setting yet |
| `home.atlassian.com` | connects | the Jira integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `html.duckduckgo.com` | connects | web search for an agent's search tool, when an agent searches | the agent's search words | when an agent uses its web search tool | don't give agents the search tool |
| `ice2.somafm.com` | connects | the radio player's stream, in a browser tab you start with Play, only when you install it (a customize template) | a stream request | when you press Play in the radio player | remove the widget (a customize template you installed) |
| `index.crates.io` | connects | crates.io's package index, from a Cloud machine's crates cache, only for an index file no peer has fresh; it sends the file's name and its ETag, no code | the index file's name and its ETag | when a Cloud machine's crates cache needs an index file no peer has fresh | create `/etc/cmux/crates-cache.disabled` on the Cloud machine |
| `inference.baseten.co` | connects | the Baseten API, when you add a Baseten key in Settings | your prompts, the files and output the agent sends, and your Baseten key | when an agent uses your Baseten key | remove the Baseten key |
| `integrate.api.nvidia.com` | connects | the NVIDIA NIM API, when you add a NVIDIA NIM key in Settings | your prompts, the files and output the agent sends, and your NVIDIA NIM key | when an agent uses your NVIDIA NIM key | remove the NVIDIA NIM key |
| `lh3.googleusercontent.com` | connects | images in agent replies | an image request (your IP address and the image's URL) | when a GitHub page or agent reply you open shows an image | not a setting: it follows what you open |
| `linear.app` | connects | the Linear integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `mail.google.com` | connects | the Google integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `mobile-api.cmux.dev` | connects | the iPhone pairing API (production) | iPhone pairing requests with your account token | when you pair an iPhone | don't pair an iPhone |
| `models.dev` | connects | the public model list the daemon's live model catalog reads (new models in the model picker) | a plain download request, no account data | when the daemon refreshes its catalog | no setting yet |
| `monitoring.googleapis.com` | connects | only `cmux vm pool` (the CI runner pool tool, run by cmux's own CI with its own Google Cloud credential): reads the pool instances' CPU use; never run by the app | the CI pool's own requests with cmux CI's credential | only `cmux vm pool`, run by cmux's own CI | the app never runs it |
| `o4507547940749312.ingest.us.sentry.io` | connects | crash and error reports, scrubbed (below), only when telemetry is on | crash and error reports, scrubbed | only after you turn telemetry on | `app.sendAnonymousTelemetry` off (the default) |
| `objects.githubusercontent.com` | connects | the pinned cmux-rd release download on a joined Linux machine (GitHub redirects release assets here) | a download request for the pinned cmux-rd release (no account data) | once per pinned cmux-rd version, on an x86_64 Linux machine joined to your hub | no setting yet; it never runs on a machine that is not joined |
| `open.bigmodel.cn` | connects | the Zhipu BigModel API, when you add a Zhipu key in Settings (its key page is on the same host) | your prompts, the files and output the agent sends, and your Zhipu key | when an agent uses your Zhipu key | remove the Zhipu key |
| `openaccess-api.clevelandart.org` | connects | museum art for backgrounds, when you search for art | your art search words, then image requests | when you search for background art | don't search for art (`appearance.background`) |
| `openaccess-cdn.clevelandart.org` | connects | museum art for backgrounds, when you search for art | your art search words, then image requests | when you search for background art | don't search for art (`appearance.background`) |
| `opencode.ai` | connects | OpenCode's config schema and installer, when you install OpenCode | a download request for the schema and installer | when you install OpenCode | don't install OpenCode |
| `openrouter.ai` | connects | OpenRouter, when you sign it in from Settings: the app trades the sign-in code for an API key | the one-time sign-in code and its verifier | once, when you sign OpenRouter in | don't sign OpenRouter in (paste a key instead) |
| `presence.cmux.dev` | connects | update channel push: tells the app a new build is out | an update-channel subscription, no account data | while the app runs, to learn a new build is out | no setting yet |
| `preview.chatmux.dev` | connects | preview pages of a chatmux session | a page request for the session's preview | when you open a chatmux session's preview | don't open previews |
| `private-user-images.githubusercontent.com` | connects | images in GitHub pages and agent replies | an image request (your IP address and the image's URL) | when a GitHub page or agent reply you open shows an image | not a setting: it follows what you open |
| `pypi.org` | connects | checks for a newer cmux CLI when installed with pip | a version lookup for the cmux CLI | when a pip-installed cmux CLI checks for a newer version | no setting yet |
| `raw.githubusercontent.com` | connects | release media reels and raw files linked in agent replies | an image request (your IP address and the image's URL) | when a GitHub page or agent reply you open shows an image | not a setting: it follows what you open |
| `registry.npmjs.org` | connects | checks for a newer cmux CLI when installed with npm; npm packages agents install | version lookups; package downloads agents ask for | when an npm-installed cmux CLI checks for a newer version, or an agent installs a package | no setting yet |
| `release-assets.githubusercontent.com` | connects | the pinned cmux-rd release download on a joined Linux machine (GitHub redirects release assets here) | a download request for the pinned cmux-rd release (no account data) | once per pinned cmux-rd version, on an x86_64 Linux machine joined to your hub | no setting yet; it never runs on a machine that is not joined |
| `router.huggingface.co` | connects | the Hugging Face Inference Providers API, when you add a Hugging Face Inference Providers key in Settings | your prompts, the files and output the agent sends, and your Hugging Face Inference Providers key | when an agent uses your Hugging Face Inference Providers key | remove the Hugging Face Inference Providers key |
| `share-dev.cmux.dev` | connects | shared workspace links in development builds | the shared workspace link's contents | development builds only, or when you choose that stack | release builds never connect unless you choose it |
| `share-staging.cmux.dev` | connects | shared workspace links on staging, only when chosen | the shared workspace link's contents | only when you choose staging | release builds use production unless you choose staging |
| `share.cmux.dev` | connects | shared workspace links (production) | the shared workspace link's contents | when you share a workspace or open a shared link | don't share or open shared links |
| `somafm.com` | connects | the radio player's station list and the song each station plays, only when you install it (a customize template) | a station list request | when the radio player widget shows stations | remove the widget (a customize template you installed) |
| `static.crates.io` | connects | crates.io's package downloads, from a Cloud machine's crates cache, only for a `.crate` neither the machine nor a peer has; it sends the package name and version | the package name and version | when a Cloud machine's crates cache needs a `.crate` neither the machine nor a peer has | create `/etc/cmux/crates-cache.disabled` on the Cloud machine |
| `stun.cloudflare.com` | connects | a STUN server for the phone and remote-desktop links when the link names none: it learns only the device's public address, no session traffic | a STUN probe: only the device's public address | when a phone or remote-desktop link starts and names no STUN server | don't start a link |
| `stun.l.google.com` | connects | the second fallback STUN server for the remote-desktop link: it learns only the public address, no session traffic | a STUN probe: only the device's public address | when the remote-desktop link's first STUN server fails | don't start a remote-desktop link |
| `stun1.l.google.com` | connects | the third STUN server of `cmux-nat-probe`, a NAT-traversal measurement tool the team runs, not the app: it learns only the probe's public address | a STUN probe: only the public address | when someone runs `cmux-nat-probe` | don't run `cmux-nat-probe` |
| `suggestqueries.google.com` | connects | search suggestions as you type, when Google is your search engine | what you type in the address bar | as you type, when Google is your search engine | `browser.omnibar.remoteSuggestions` off, or another `browser.searchEngine` |
| `thumb.wikimedia.org` | connects | museum art for backgrounds, when you search for art | your art search words, then image requests | when you search for background art | don't search for art (`appearance.background`) |
| `uniichat.com` | connects | the hosted UniiChat agent, only when you start it | your messages to the hosted agent | only when you start the UniiChat agent | don't start it |
| `unpkg.com` | connects | scripts and styles an agent's rendered page may load | a file request (your IP address and the file's URL) | when an agent's rendered page loads it | not a setting: it follows the page you open |
| `upload.wikimedia.org` | connects | museum art for backgrounds, when you search for art | your art search words, then image requests | when you search for background art | don't search for art (`appearance.background`) |
| `uploads.github.com` | connects | GitHub uploads, through the GitHub CLI | your GitHub token and the repo, PR and file requests you or an agent make | when you or an agent use git, gh or the app's GitHub views | sign out of GitHub (`gh auth logout`) |
| `user-images.githubusercontent.com` | connects | images in GitHub pages and agent replies | an image request (your IP address and the image's URL) | when a GitHub page or agent reply you open shows an image | not a setting: it follows what you open |
| `vm-staging.cmux.dev` | connects | cmux Cloud machine API on staging, only when chosen | your cmux account token and the Cloud requests you make | only when you choose staging | release builds use production unless you choose staging |
| `vm.cmux.dev` | connects | cmux Cloud machine API (production) | your cmux account token and the Cloud requests you make | when you use cmux Cloud | don't sign in to cmux Cloud |
| `www.artic.edu` | connects | museum art for backgrounds, when you search for art | your art search words, then image requests | when you search for background art | don't search for art (`appearance.background`) |
| `www.cmux.com` | connects | the same site as cmux.com; deep links and sign-in | sign-in callbacks and deep link requests | when you sign in or open a deep link | no setting yet |
| `www.linkedin.com` | connects | the LinkedIn integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |
| `www.notion.so` | connects | the Notion integration, only when an agent uses it in your signed-in browser | the requests your signed-in browser makes for the agent's task, with that site's cookies | only when an agent uses that integration in your signed-in browser | don't give an agent the integration, or sign out of the site in cmux's browser |

<!-- egress-hosts:end -->

### Pages the app opens when you ask

| Host | Kind | What for |
|---|---|---|
| `lmstudio.ai` | opens | a provider's download page, opened from Settings |
| `console.mistral.ai` | opens | a page to get an API key, opened from Settings |
| `console.x.ai` | opens | a page to get an API key, opened from Settings |
| `accounts.x.ai` | opens | a provider's sign-in page, opened when you sign that agent in |
| `airbnb.com` | opens | a site the address bar suggests before it is in your history |
| `amazon.com` | opens | a site the address bar suggests before it is in your history |
| `console.aws.amazon.com` | opens | a page to get an API key, opened from Settings |
| `anthropic.com` | opens | a site the address bar suggests; also an Anthropic host name the app recognizes |
| `auth.anthropic.com` | opens | Anthropic sign-in pages, opened when you sign an agent in |
| `console.anthropic.com` | opens | Anthropic sign-in pages, opened when you sign an agent in |
| `docs.anthropic.com` | opens | setup docs for an agent, opened from onboarding |
| `apple.com` | opens | a site the address bar suggests before it is in your history |
| `developer.apple.com` | opens | a site the address bar suggests before it is in your history |
| `apps.apple.com` | opens | Apple's App Store subscription management page, opened from the iPhone app's Delete Account warning when StoreKit can't show its own sheet |
| `www.baidu.com` | opens | a search engine, when you search with it |
| `bbc.com` | opens | a site the address bar suggests before it is in your history |
| `bing.com` | opens | a site the address bar suggests before it is in your history |
| `www.bing.com` | opens | a search engine, when you search with it |
| `booking.com` | opens | a site the address bar suggests before it is in your history |
| `search.brave.com` | opens | a search engine, when you search with it |
| `claude.com` | opens | Anthropic sign-in pages, opened when you sign an agent in |
| `platform.claude.com` | opens | Anthropic sign-in pages, opened when you sign an agent in |
| `cursor.com` | opens | a provider's sign-in page, opened when you sign that agent in |
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
| `controlplane.tailscale.com` | identifier | Tailscale's default control server, compared with the one a machine is already signed in to before cmux adds it to your tailnet; the machine's own `tailscale` connects to it, never the app |
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
| `ai.azure.com` | opens | a provider's page to get an API key, opened from Settings |
| `app.baseten.co` | opens | a provider's page to get an API key, opened from Settings |
| `app.fireworks.ai` | opens | a provider's page to get an API key, opened from Settings |
| `bailian.console.aliyun.com` | opens | a provider's page to get an API key, opened from Settings |
| `build.nvidia.com` | opens | a provider's page to get an API key, opened from Settings |
| `cloud.cerebras.ai` | opens | a provider's page to get an API key, opened from Settings |
| `dev.meta.ai` | opens | a provider's page to get an API key and its docs, opened from Settings |
| `modelstudio.console.alibabacloud.com` | opens | a provider's page to get an API key, opened from Settings |
| `morphllm.com` | opens | a provider's page to get an API key, opened from Settings |
| `platform.kimi.ai` | opens | a provider's page to get an API key, opened from Settings |
| `platform.minimax.io` | opens | a provider's page to get an API key or a plan, and its docs, opened from Settings |
| `platform.minimaxi.com` | opens | a provider's page to get an API key or a plan, opened from Settings |
| `platform.moonshot.cn` | opens | a provider's page to get an API key, opened from Settings |
| `z.ai` | opens | a page to get an API key, opened from Settings |
| `ai.google.dev` | opens | a provider's docs page, opened from Settings |
| `api-docs.deepseek.com` | opens | a provider's docs page, opened from Settings |
| `code.claude.com` | opens | a provider's docs page, opened from Settings |
| `docs.api.nvidia.com` | opens | a provider's docs page, opened from Settings |
| `docs.aws.amazon.com` | opens | a provider's docs page, opened from Settings |
| `docs.baseten.co` | opens | a provider's docs page, opened from Settings |
| `docs.cloud.google.com` | opens | a provider's docs page, opened from Settings |
| `docs.fireworks.ai` | opens | a provider's docs page, opened from Settings |
| `docs.mistral.ai` | opens | a provider's docs page, opened from Settings |
| `docs.modelstudio.console.alibabacloud.com` | opens | a provider's docs page, opened from Settings |
| `docs.ollama.com` | opens | a provider's docs page, opened from Settings |
| `docs.together.ai` | opens | a provider's docs page, opened from Settings |
| `docs.x.ai` | opens | a provider's docs page, opened from Settings |
| `docs.z.ai` | opens | a provider's docs page, opened from Settings |
| `geminicli.com` | opens | a provider's docs page, opened from Settings |
| `inference-docs.cerebras.ai` | opens | a provider's docs page, opened from Settings |
| `learn.chatgpt.com` | opens | a provider's docs page, opened from Settings |
| `learn.microsoft.com` | opens | a provider's docs page, opened from Settings |
| `platform.moonshot.ai` | opens | a provider's docs page, opened from Settings |
| `www.morphllm.com` | opens | a provider's docs page, opened from Settings |
| `api.slack.com` | opens | Slack's app page that shows the configuration token, opened from Settings |
| `grok.com` | opens | Grok's sign-in and plans pages, opened when you sign that agent in or from Settings |
| `www.grok.com` | opens | a provider's sign-in page, opened when you sign that agent in |
| `kimi.ai` | opens | a provider's sign-in page, opened when you sign that agent in |
| `kimi.com` | opens | a provider's sign-in page, opened when you sign that agent in |
| `www.kimi.ai` | opens | a provider's sign-in page or API key page, opened when you sign that agent in or from Settings |
| `www.kimi.com` | opens | a provider's sign-in page or API key page, opened when you sign that agent in or from Settings |

### Names the app never contacts

| Host | Kind | What for |
|---|---|---|
| `x.ai` | identifier | an xAI tool method name, not a host |
| `customize.io` | identifier | the error code `cmux customize` prints when a file read or write fails, not a host |
| `community.io` | identifier | the error code `cmux community` prints when a staging folder cannot be made, not a host |
| `live.com` | identifier | an email sender domain that verification-code AutoFill counts as Microsoft's; never fetched |
| `microsoftonline.com` | identifier | an email sender domain that verification-code AutoFill counts as Microsoft's; never fetched |
| `outlook.com` | identifier | an email sender domain that verification-code AutoFill counts as Microsoft's; never fetched |
| `office.com` | identifier | an email sender domain that verification-code AutoFill counts as Microsoft's; never fetched |
| `xbox.com` | identifier | an email sender domain that verification-code AutoFill counts as Microsoft's; never fetched |
| `skype.com` | identifier | an email sender domain that verification-code AutoFill counts as Microsoft's; never fetched |
| `facebookmail.com` | identifier | an email sender domain that verification-code AutoFill counts as Meta's; never fetched |
| `meta.com` | identifier | an email sender domain that verification-code AutoFill counts as Meta's; never fetched |
| `steampowered.com` | identifier | an email sender domain that verification-code AutoFill counts as Valve's; never fetched |
| `steamcommunity.com` | identifier | an email sender domain that verification-code AutoFill counts as Valve's; never fetched |
| `icloud.com` | identifier | an email sender domain that verification-code AutoFill counts as Apple's; never fetched |
| `netlify.app` | identifier | a shared hosting domain, so sites under it are told apart |
| `ngrok-free.app` | identifier | a shared hosting domain, so sites under it are told apart |
| `vercel.app` | identifier | a shared hosting domain, so sites under it are told apart |
| `web.app` | identifier | a shared hosting domain, so sites under it are told apart |
| `hf.co` | identifier | a git host name, so it is not shown as one of your computers |
| `huggingface.co` | identifier | a git host name, so it is not shown as one of your computers |
| `repl.co` | identifier | a shared hosting domain, so sites under it are told apart |
| `manaflow.ai` | identifier | an email domain of the cmux team: an account under it gets the team's verbose connectivity diagnostics, and the iPhone app reports its major connectivity incidents to the cmux mobile service for the team's Slack; nothing is sent to the domain itself |
| `manaflow.com` | identifier | an email domain of the cmux team, as `manaflow.ai` |
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
| `meet.google.com` | identifier | the Google Meet host name, so an agent finds the call you have open in a cmux browser tab to read its captions; never fetched by the app |
| `youtu.be` | identifier | a YouTube host name, so a pasted video address can be a background (read as its video id); never fetched |
| `youtube-nocookie.com` | identifier | a YouTube host name, so a pasted video address can be a background (read as its video id); never fetched |
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
| `schemas.microsoft.com` | identifier | the Task Scheduler XML namespace in acpmux's Windows logon task, never fetched |
| `freestyle.sh` | identifier | a cloud host name the app recognizes |
| `ac.uk` | identifier | a public suffix, so sites under it are told apart |
| `ltd.uk` | identifier | a public suffix, so sites under it are told apart |
| `me.uk` | identifier | a public suffix, so sites under it are told apart |
| `plc.uk` | identifier | a public suffix, so sites under it are told apart |
| `turn.cloudflare.com` | identifier | the TURN relay host the iPhone's blocked-network message asks IT to allow; the code never dials this name (the link's ICE servers come from the relay; config/network/allowlist.json lists it) |
| `get.docker.com` | identifier | the Docker installer URL written into a migrated project's Cloud machine setup line; the machine runs it when it lacks Docker, the app never fetches it |
| `mise.run` | identifier | the mise installer URL written into a migrated project's Cloud machine setup line; the machine runs it when it lacks mise, the app never fetches it |
| `install.determinate.systems` | identifier | the Nix installer URL written into a migrated Nix project's Cloud machine setup line; the machine runs it when it lacks Nix, the app never fetches it |
| `get.jetify.com` | identifier | the devbox installer URL written into a migrated devbox project's Cloud machine setup line; the app never fetches it |
| `dot.net` | identifier | the .NET installer URL written into a Cloud machine setup line when a migrated devcontainer names the dotnet feature; the app never fetches it |
| `aka.ms` | identifier | the Azure CLI installer URL written into a Cloud machine setup line when a migrated devcontainer names the azure-cli feature; the app never fetches it |
| `git-lfs.github.com` | identifier | the version line of a Git LFS pointer file, matched when seeding a project, never fetched |
| `1password.com` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `appstoreconnect.apple.com` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `atlassian.net` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `cloudflare.com` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `dash.cloudflare.com` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `dashboard.stripe.com` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `netlify.com` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `portal.azure.com` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `sentry.io` | identifier | a sign-in site the iPhone app compares a page's host with, to stream that page from the Mac instead of loading it on the phone; never fetched for this |
| `api.llama.com` | identifier | Meta's Llama API host, compared with an endpoint you enter so it gets Meta's settings; the app connects to the endpoint you enter |
| `openai.azure.com` | identifier | an Azure OpenAI host suffix, compared with the endpoint you enter so it gets Azure's settings; the app connects to the endpoint you enter |
| `cognitiveservices.azure.com` | identifier | an Azure AI host suffix, compared with the endpoint you enter so it gets Azure's settings; the app connects to the endpoint you enter |
| `services.ai.azure.com` | identifier | an Azure AI Foundry host suffix, compared with the endpoint you enter so it gets Azure's settings; the app connects to the endpoint you enter |
| `console.cmux.dev` | identifier | the cmux console host GitHub returns you to after installing the GitHub App: the in-app sign-in panel compares the page it reaches with it and stops there |
| `console-staging.cmux.dev` | identifier | the staging cmux console host GitHub returns you to in staging builds: the in-app sign-in panel compares the page it reaches with it and stops there |
| `share.io` | identifier | the error code a workspace share prints when its listing cannot be read or encoded, not a host |
| `tool.sh` | identifier | a file name in a test fixture, not a host |
| `try.sh` | identifier | the name of a script on the Mac that serves the iPhone try-a-PR picker, not a host |

### Samples and placeholders

| Host | Kind | What for |
|---|---|---|
| `api.datadoghq.com` | example | a sample secret's host in the env-secrets playground |
| `hooks.stripe.com` | example | a sample secret's host in the env-secrets playground |
| `http-intake.logs.datadoghq.com` | example | a sample secret's host in the env-secrets playground |
| `maps.googleapis.com` | example | a sample secret's host in the env-secrets playground |
| `docs.github.com` | example | a sample error text |
| `api.stripe.com` | example | an example in a tool description |
| `github.com.evil` | example | a value in a self-check |
| `webauthn.io` | example | a sample saved passkey |
| `cdn-example.net` | example | a sample in a dialog |
| `mini.tail1234.ts.net` | example | a placeholder in a settings field |
| `*.example.ts.net` | example | a device address in the Debug menu's sample device list |
| `r.org` | example | a value in a self-check |
| `www.bbc.co.uk` | example | a sample site in the iPhone site-monogram gallery |
| `developers.cloudflare.com` | example | a link in a sample agent reply in the iPhone Feed's preview data |

### Text that looks like a host name

| Host | Kind | What for |
|---|---|---|
| `command.io` | not-a-host | an error code for a custom command's file error |
| `acpmux.io` | not-a-host | an error code for a failed write to the local acpmux socket in the SSH benchmark |
| `cmux.app` | not-a-host | the app bundle name `cmux app try` builds and copies |
| `failed.app` | not-a-host | the app bundle `cmux app try` sets aside when a swap fails |
| `prior.app` | not-a-host | the app bundle `cmux app try` sets aside |
| `replaced.app` | not-a-host | the app bundle `cmux app try` sets aside when it replaces a copy |
| `undone.app` | not-a-host | the app bundle `cmux app try undo` sets aside |
| `runner-fork-guard.sh` | not-a-host | a script file name in the VM pool runner |
| `runner-guest.sh` | not-a-host | a script file name in the VM pool runner |
| `task.ai` | not-a-host | a symbol or icon name |
| `argument.app` | not-a-host | a localized string key |
| `toast.detail.io` | not-a-host | a localized string key |
| `projection.io` | not-a-host | an error code of projected folders |
| `cmux-ios-com.cmux.app` | not-a-host | a URL scheme or bundle id |
| `red.sh` | not-a-host | a script file name in a Cloud journey repro capsule |
| `green.sh` | not-a-host | a script file name in a Cloud journey repro capsule |
| `run.sh` | not-a-host | the runner script file name `cmux-repro` writes |
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
| `build.sh` | not-a-host | a file name |
| `cmux-debug-cli.sh` | not-a-host | a file name |
| `libopenh264-2.6.0-linux-arm64.8.so` | not-a-host | a file name |
| `libopenh264-2.6.0-linux64.8.so` | not-a-host | a file name |
