# cmux next: browser egress control (design)

Tracker: EPIC cx-d0d.52, this doc cx-d0d.52.1. Binding input: decision BROWSER-EGRESS-CONTROL (spec repo `decisions.md`, 2026-10-07, Lawrence: paid feature). Doc only; no code lands with it. Labels: **FACT** has a source (section 14) or a file in this repo; **GUESS** is not verified; **TEST** names the check that must prove it before the feature ships.

## 0. Scope and one conflict

The decision: a browser (profile, workspace or single tab) can egress through a cmux VPN exit, a cmux-provided residential proxy (paid), or the user's own proxy (HTTP, SOCKS5 or WireGuard, credentials in Keychain). Agents switch egress with `browser.egress.set {target, exit}` within team policy. Requirements: per-profile network isolation with no leak (DNS included; WebRTC and QUIC follow the exit or are blocked), a badge, team policy, metering for billing, an audit of switches in Agent activity, abuse limits, and local-only browsers default to direct.

Conflict: the decision allows a **single tab** as a target; the brief says egress is per **store** (profile, incognito store, proxy store), never per process. Chromium and WebKit attach a proxy to a network context (store), not to a tab. Resolution in this doc: a tab target gets its own **ephemeral store** (no shared cookies with its profile). See decision E1 in section 13.

## 1. Design in one paragraph

Every store with an egress gets **one local egress proxy listener** owned by cmux (the app on macOS, the browser host on a Linux machine). The engine sends **all** traffic of that store to the listener (`fixed_servers`, `<-loopback>` bypass removal as in remote-localhost.md section 5). The listener forwards each connection to the chosen **exit** (cmux WireGuard exit, residential vendor, or the user's proxy), adds the upstream credentials itself, counts bytes, applies policy, and never falls back to direct. The engine never holds an upstream credential and never resolves a proxied name. Leak paths that do not use the store's network context (DNS prefetch, WebRTC UDP, QUIC, WebTransport, process-level services) are closed by per-store preferences where they exist and by tests where they do not.

Why one local listener for every source: (a) Chrome-style CEF never answers a proxy auth challenge (FACT, remote-localhost.md section 5, verified 2026-09-30), so credentialed upstreams need a local hop anyway; (b) one place for metering, spend caps, the switch, the kill on cap, and the private-range rule; (c) the same component serves CEF, WebKit and the headless host.

## 2. Where egress attaches (state model)

| Unit | Engine object | Egress | Notes |
| --- | --- | --- | --- |
| Profile (`BrowserProfileID`, daemon-owned) | CEF `CefRequestContext` per profile (browser.md "Per-profile data dirs"); WebKit `WKWebsiteDataStore(forIdentifier:)` | yes, default for all its tabs | FACT: both engines already map a profile to one store |
| Workspace | a derived store per profile x workspace (pattern of remote-localhost.md: profile x machine) | yes | keeps the profile's login out of a workspace that uses another exit only if E1 says so |
| Tab | an ephemeral derived store | yes (E1) | no shared cookies with the profile |
| Incognito store (headless host) | `Target.createBrowserContext` | yes | today `session.configure` refuses incognito + proxy (FACT, headless_configure.rs "incognito with a proxy ... is not supported yet"); lift that refusal in child .2 |
| Proxy store (headless host) | `Target.createBrowserContext {proxyServer, proxyBypassList}` | yes, already built | FACT: driver.rs `create_proxy_context`; credentials are refused on headless today |

State owner: the **daemon** owns the egress assignment (`store -> exit id`, revision, who set it) as part of the profile/store record; the engine side only applies it. The **Cloud backend** owns the exit catalog, entitlements, spend and metering ledgers. **Keychain** (macOS) owns BYO secrets; the daemon stores only a Keychain reference.

Default: no egress = direct. A local-only browser (this Mac, no Cloud) stays direct unless a person picks an exit (decision text).

## 3. Sources and their data paths

### 3.1 cmux VPN exits (WireGuard)

- Exit = a small Linux VM with a public IPv4 (and IPv6 if E6 says so) per region, run by cmux. It terminates WireGuard and runs an HTTP CONNECT proxy and a DNS resolver on its tunnel address only.
- Client side: the local egress proxy forwards `CONNECT host:port` (host as a **name**) through a userspace WireGuard tunnel to the exit's proxy. The exit resolves the name. No local DNS for proxied traffic.
- Reuse: `cmux-remote` already has a userspace WireGuard hub (boringtun) that owns one tunnel per key and exposes SOCKS5 CONNECT on an owner-only Unix socket (FACT, `cmux-tui/crates/cmux-remote/src/wireguard_hub.rs`). Two gaps: the hub accepts **literal IP targets only** and **only targets inside the tunnel's routes**. Egress needs name targets sent to the exit proxy, not to the hub; so the egress path dials the exit proxy's tunnel IP (a literal, inside routes) through the hub and speaks CONNECT-with-name to it. No hub change for names. One WireGuard key per device per exit; keys minted by the backend (same rule as the hub: one live session per key).
- Exit-side policy (authoritative): refuse private, loopback, link-local and metadata ranges after its own resolution (section 7.3), refuse port 25, apply per-key rate limits, keep connection metadata (time, key id, destination host, bytes) for the abuse window (E8), never content.
- Where exits run: GUESS any provider with public IPs and UDP (Hetzner, AWS, GCP). Not Freestyle (no public UDP ingress verified). Datacenter IPs: many sites challenge them; residential (3.2) is the answer for those sites.

### 3.2 Residential proxies (cmux-provided, paid add-on)

- cmux holds the vendor account; each cmux team maps to one **vendor sub-user** with its own credentials and a vendor-side traffic limit (FACT: Oxylabs residential public API creates sub-users with daily/monthly/lifetime GB limits; IPRoyal sub-users have a fixed traffic allocation; Decodo has sub-users with traffic limits, section 9).
- The local egress proxy holds the sub-user credential (fetched from the backend per session, short-lived in memory, never written to the engine) and dials the vendor gateway with HTTP CONNECT and `Proxy-Authorization`. Geo (country, city) and session stickiness are vendor username parameters.
- Default session mode: **sticky** (one exit IP per store for its life or up to the vendor's maximum), not rotation per request. Rotation per request is the shape of credential stuffing and scraping at scale (section 7.2).
- Legal precondition: reselling needs a written reseller agreement (FACT: Bright Data AUP forbids unauthorized reselling; its partner program defines resellers). Assume the same for every vendor until a contract says otherwise. Vendor KYC also flows down: Bright Data residential is for KYC-verified companies only since 2026-07-07 (FACT). So the add-on needs **our** KYC of the team before the first residential byte (E9).

### 3.3 Bring your own (BYO)

- Kinds: HTTP CONNECT, HTTPS (TLS to the proxy), SOCKS5 (username/password), WireGuard config (`.conf`).
- Secrets: macOS Keychain item per exit (internet password, service `cmux browser egress`, account = exit id). The daemon stores `{exit id, kind, host, port, keychain ref}`; the app's local egress proxy reads the secret. For WireGuard, the private key is the secret and the tunnel runs in the same userspace hub as 3.1.
- **Test connection** (required before save): through the exact path a store will use, fetch a cmux echo endpoint (`GET https://egress-check.<cmux domain>/v1/ip`, new, child .3) and show the exit IP, its ASN/country (from the echo), the round-trip time, and whether the proxy resolved the name (the echo sees no local resolver; section 4 DNS canary). Fail closed: an exit that fails the test is not selectable.
- Cloud machines (headless host on a VM): a BYO secret must reach the VM. See E5.

### 3.4 Agent-controlled egress

`browser.egress.set {target, exit, reason?}` (section 6). Agents never see secrets; they pick an exit id from `browser.egress.list` (ids, kind, region, cost class, allowed-by-policy flag).

## 4. No-leak rules (each one has a test)

A leak = any packet caused by a store with an egress that leaves the machine other than to its exit (or to the local egress listener on loopback). Each row is a rule, its mechanism, and the test that proves it (section 12 says where tests run).

| # | Path | Rule and mechanism | Test |
| --- | --- | --- | --- |
| L1 | DNS for page loads | proxied by name: HTTP CONNECT carries the host name; the exit resolves. FACT for SOCKS5 in Chromium: "The hostname for these URLs will be resolved by the proxy server" (Chromium SOCKS page). | DNS canary: unique name per run under a zone we own; pass when the authoritative server sees the query **only** from the exit's resolver |
| L2 | DNS prefetch / preconnect | per store: CEF profile pref `net.network_prediction_options = 2` (never). FACT: Chromium documents the DNS prefetcher as the main component that bypasses the proxy; its process-wide fix (`--host-resolver-rules`) cannot be per store, so we use the per-profile pref. WebKit: no public switch; block `rel=dns-prefetch`/`preconnect` hints (FACT: WebKit DNS prefetch bypasses `proxyConfigurations`, mysk 2026-08-04). | canary names in `<link rel=dns-prefetch>`, `preconnect`, and hover/omnibox prediction; pass = no query from the device |
| L3 | WebRTC | per store: CEF pref `webrtc.ip_handling_policy = disable_non_proxied_udp` (FACT: policy value "uses either UDP SOCKS proxying or will fallback to TCP proxying"). Known gap: Chromium issue 41345813 "disable_non_proxied_udp allows non-proxied TURN" (2017, status not confirmed). WebKit: no per-store switch; disable WebRTC in egress stores (`RTCPeerConnection` removed by a user script before page scripts) until a probe proves otherwise. | STUN/TURN canary page with ICE candidates; pass = no host/srflx candidate with the device IP, no UDP from the device to the canary TURN |
| L4 | QUIC / HTTP3 | Chromium does not send QUIC through an HTTP or SOCKS proxy (FACT for our setup: remote-localhost.md "QUIC is off for proxied traffic"); QUIC proxies are a separate `quic://` type (FACT, Chromium proxy docs). | origin that advertises `Alt-Svc: h3`; pass = no UDP 443 from the device |
| L5 | WebTransport | WebKit: leaks around the proxy (FACT, mysk 2026-08-04) -> disabled in egress stores. Chromium: unknown -> TEST; if it leaks, refuse the egress for that engine until fixed (no process-wide switch) | WebTransport canary; pass = no UDP from the device |
| L6 | IPv6 | the only proxied hop is IPv4 loopback to the listener; the exit picks v4/v6. Leak only via L2-L5. For WireGuard exits without v6, the exit resolver returns A only (E6). | dual-stack canary; pass = canary sees only exit addresses |
| L7 | Service workers, workers, fetch keepalive, beacons, downloads | same network context as the store -> proxied. GUESS for every one; TEST each. | a page that registers a SW, then the SW fetches a canary; `sendBeacon` on unload; a download |
| L8 | Extensions | extension traffic in the profile uses the profile context (GUESS, TEST). Extensions with the `proxy` permission can replace the profile proxy pref -> an egress store refuses to enable such extensions, and the app re-checks the effective proxy after every extension change. | install a test extension that sets `chrome.proxy`; pass = refused or no effect |
| L9 | Process-level services (CEF global context: component update, Safe Browsing lists, variations, GCM, crash upload) | these are not store traffic; they do not carry the store's identity but do show the device IP to Google. Rule: allowed direct, documented in the egress settings text. The headless host already passes `--disable-component-update`, `--disable-background-networking`, `--disable-sync` (FACT, pipe.rs default_args). Real-time Safe Browsing URL lookups: GUESS per profile; TEST. | packet capture during a session; classify every non-exit flow by process and purpose |
| L10 | WebAuthn Related Origin Requests (WebKit) | leaks the device IP (FACT, mysk). Disable WebAuthn in WebKit egress stores, or open such pages in Chromium. | ROR canary `/.well-known/webauthn` |
| L11 | Switch window | after `egress.set`, existing connections of the store must not carry new requests. CEF: `CefRequestContext::CloseAllConnections` after the pref change (GUESS that the API is in CEF 154; TEST). Headless: dispose the old proxy context, move tabs (FACT: the host already re-creates the store). | request burst during a switch; pass = every request after the switch ack arrives from the new exit |
| L12 | Listener failure | the local listener never falls back to direct; a dead exit gives an error page that names the exit (pattern: remote-localhost 502 page). | kill the exit mid-load |
| L13 | CEF network service | the network service is one helper process for all stores; per-store proxy prefs apply per network context. The global context is L9. | covered by L1-L9 per store with two stores on different exits at once |

Rule for the UI: an egress that cannot meet every row for an engine is **not offered** for that engine (the badge says why). No silent degrade.

## 5. Per-engine mechanics

### 5.1 CEF (Chrome style, macOS app)

- Per-profile request context already exists (browser.md). Apply `proxy = {mode: fixed_servers, server: http://127.0.0.1:<port>, bypass_list: "<-loopback>"}` with `CefRequestContext::SetPreference("proxy", ...)` (FACT: shim_proxy.mm does this for remote localhost), plus `net.network_prediction_options = 2` and `webrtc.ip_handling_policy = disable_non_proxied_udp` on the same context.
- Listener authentication: peer-process check (libproc): only this app and its Chromium helpers may connect (FACT: remote-localhost.md section 5). One listener per store, random port.
- Composition with remote localhost: a store can have both a machine (loopback goes to the machine) and an egress (everything else goes to the exit). One listener does both: loopback names to the machine stream, all other names to the exit. Children .2 and the remote-localhost owner agree on one listener type.

### 5.2 WebKit (macOS 14+)

- `WKWebsiteDataStore.proxyConfigurations` takes HTTP CONNECT and SOCKSv5 `ProxyConfiguration`s, with credentials (FACT, Apple API; issue manaflow-ai/cmux#6639 asks for it).
- The WebKit networking process is not a child of the app, so the peer-process check fails; use the per-launch credential on the listener (FACT: remote-localhost.md section 5 keeps such a credential listener for WebKit).
- Known leaks around it: DNS prefetch, WebAuthn ROR, WebTransport (FACT, mysk 2026-08-04, no Apple fix named). A third-party app also saw later navigations of a WebView go direct while the first load was proxied, cause open (FACT as a report, webspace_app PR 604; not reproduced by us). Therefore WebKit egress ships **only** after our own probe (child .2, extending `scripts/cmux-next/webkit-loopback-proxy-probe.swift`) passes L1-L13 on the current macOS. Until then a WebKit tab in an egress store is refused with "Open in Chromium" (E3).

### 5.3 Headless browser host (Linux, Cloud VMs and server hosts)

- Proxy stores via `Target.createBrowserContext {proxyServer, proxyBypassList}` (FACT, built). Point `proxyServer` at the host's own local egress listener (same component as 5.1, Rust, in the host), so credentials and metering work the same way and the current refusal of proxy credentials stays correct.
- Listener authentication on Linux: the host owns the Chrome process tree; accept only peers whose socket inode belongs to a PID in the host's Chrome session (procfs). GUESS that this is cheap enough per accept; TEST.
- WebRTC and prediction for CDP browser contexts: there is no per-context pref API over CDP (GUESS). Options in E4: apply `--force-webrtc-ip-handling-policy=disable_non_proxied_udp` and prediction off **process-wide** for the headless host (agents rarely need P2P WebRTC), or refuse egress stores on headless until a per-context mechanism exists.
- The browser role on the cmux-next image (cloud-automation.md section 31) already throttles background tabs and keeps the sandbox on; egress changes neither.

## 6. Agent op, badge, audit

- Op: `browser.egress.set {target: {profile | workspace | tab}, exit: <exit id> | "direct", reason?: string}` -> `{applied_revision, exit: {id, kind, region}, closed_connections}`. Typed protocol op (protocol spec + SDK bindings in child .6).
- `browser.egress.list` -> exits allowed for the caller, with `cost_class` (free, metered) and `requires_confirmation`.
- Who may call: a person always (in their own profiles); an agent only when team policy lists it (section 7.1), only on stores its lease covers (automation-lease.md), and never on a person's signed-in default profile unless the person granted it.
- Badge: a chip on the tab (and workspace) with the exit's short label and kind icon (VPN / residential / own); states `applying`, `active`, `failed` (red, with reason), `metered` (shows that cost accrues). Hover: exit, region, observed exit IP (from the last test), who set it.
- Audit: every `set`, refusal, cap stop and failure writes one Agent activity record `{at, actor (person/agent id), target, from, to, reason, result}` and one backend audit row (team-visible). No URLs in the audit beyond the store id.

## 7. Policy and abuse limits

### 7.1 Team policy keys (team-policy.ts, new)

- `browser.egress.allowedKinds`: subset of `direct, vpn, residential, byo`. Default `direct, vpn, byo` for paid plans; `residential` only with the add-on.
- `browser.egress.allowedExits`: optional list of exit ids or regions.
- `browser.egress.agentsMaySwitch`: `none | listed | all`, with a list of agent identities. Default `none`.
- `browser.egress.spendCapUsd`: monthly cap for metered exits (residential). Default set at add-on purchase; 0 = metered exits off.
- `browser.egress.requirePersonForMetered`: default true (an agent can switch to a metered exit only if a person confirmed that exit for that workspace once).

### 7.2 Abuse limits

- Switch rate: at most 6 switches per store per 10 minutes and 60 per team per hour (GUESS numbers; tune with data). Over the limit = refused + audit.
- No per-request rotation by default (3.2). Rotation is a separate policy flag, off, and not available to agents.
- Destinations: vendor blocklists apply (Bright Data blocks government sites on all networks and enforces robots.txt on residential, FACT). Our own floor: no SMTP, no private ranges at the exit, no cmux-owned zones (reuse `DENIED_EGRESS_DOMAINS`, FACT backend `egress-hosts.ts`).
- Credential-stuffing signal: many distinct login form submissions (password fields) to one site across exits within a short time -> stop the store, notify the team owner. GUESS thresholds; this is detection, not proof.
- Provider ToS: our ToS for the add-on flows down every vendor's acceptable use policy; violation = add-on suspended.

### 7.3 No bypass of FETCH-PRIVATE-RANGES

- Today the host checks a URL's literal host and, after a fetch, the response's `remoteIPAddress` (FACT: gate/fetch.rs `rebinding_refusal`). Under a proxy, Chromium reports the proxy's address as the remote address (FACT, Chromium 143, tests/chromium/proxy_ranges.rs; the page behind it loads and is readable before the after-the-fact stop). Landed 2026-10-07 in the gate (gate/proxy.rs): remote sessions set no proxy; a proxy's own address meets the range rule; a proxied session's URL names that this machine resolves into a refused range are refused before dispatch. With our design that is 127.0.0.1, a private range: every proxied fetch from a remote session would be refused, and the real destination address is never seen.
- Rule: for a store with an egress, the host keeps the literal-host check and skips the after-the-fact address check. The range rule moves to the hop that resolves names:
  - cmux VPN exits: the exit enforces it after its own resolution (built into the exit image).
  - Residential: vendors do not offer it (GUESS). The local listener refuses, before dial, names that are private by definition (`localhost`, `*.localhost`, `*.internal`, `*.local`, metadata names). A public name that resolves to a private address at the vendor reaches the vendor's network, not ours: accepted risk, written in the add-on terms.
  - BYO: the exit is the user's own network. Allowed for local sessions only, the same as today's rule for local callers; remote (relay) sessions refuse BYO exits.
- The owner-policy allow list still overrides (FETCH-PRIVATE-RANGES base layer).

## 8. Billing and metering

- Count at the local egress listener: bytes up and down per store per exit per minute (it sees every byte). Residential vendors bill per GB (FACT, all vendors in section 9); GUESS that they count both directions; check per contract.
- Report: the app/host sends usage batches to the backend usage meter (FACT: `usage-meter-do.ts` exists with per-key retention and admission; add an `egress` meter kind). Idempotent batch ids; offline batches flush later.
- Spend cap enforcement in three layers: (1) the listener stops metered traffic when the backend says the team is at cap (pushed, and checked at each new connection with a cached allowance); (2) backend credit ledger; (3) vendor sub-user traffic limit set to the cap plus a margin (FACT: Oxylabs/IPRoyal/Decodo sub-user limits).
- Reconcile daily with the vendor usage API (FACT: Oxylabs `/client-stats`, `/target-stats`; IPRoyal sub-user stats) and alert on more than 5 % drift (GUESS threshold).
- Price: add-on per GB at cost plus margin, or a GB bundle in Pro/Max (E10).

## 9. Providers (residential)

Prices are list prices seen in October 2026 through vendor pages and reviews; all change often.

| Vendor | Price (residential) | Team isolation API | Sourcing / compliance | Notes |
| --- | --- | --- | --- | --- |
| Oxylabs | $8/GB PAYG reported; plans $6/GB (5 GB) to $2.50/GB (1 TB) (reviews, 2026) | Residential Public API: create/modify/delete sub-users, traffic limits, `/client-stats`, `/target-stats`, JWT auth (FACT, developers.oxylabs.io) | EWDCI member (FACT) | best documented sub-user API |
| Decodo (ex Smartproxy) | PAYG $4/GB; plans $3.75 to $2/GB (FACT, vendor pricing page) | sub-users with traffic limits via API; system-generated passwords only (reviews) | EWDCI co-founder, "explicit consent" claim (FACT, vendor page) | reseller plans reported, not confirmed (GUESS) |
| IPRoyal | $7.35/GB PAYG at 1 GB down to $1.84/GB from 10 TB; traffic does not expire (FACT, vendor pricing) | `resi-api.iproyal.com/v1/residential-subusers`, fixed allocation per sub-user (FACT, docs) | consent claims not reviewed here | sub-user minimum spend reported up to $1,000 (review, GUESS) |
| Bright Data | $8/GB PAYG list ($4 promo); plans to $5/GB list (reviews) | zones and sub-accounts (not reviewed in depth) | residential KYC, company accounts only since 2026-07-07; AUP forbids unauthorized reselling; reseller program by agreement (FACT, docs/AUP/partner guide) | strongest compliance gate; slowest to start |
| NetNut | n/a | n/a | FBI seized NetNut domains on 2026-07-02; Google tied it to the Popa network of about 2M devices enrolled without clear consent (FACT, multiple reports incl. vendor-independent) | **excluded** |

Recommendation (GUESS until sales calls): start with **Oxylabs** (sub-user API + limits + EWDCI) and keep **Decodo** as the second vendor behind the same adapter. Both need a reseller agreement before launch. Selection criteria in order: written reseller right, consent evidence for the pool (EWDCI-style audit, revocable consent, no SDK in apps without a clear prompt), sub-user API with hard limits, usage API, price.

cmux VPN exits cost (GUESS): one small VM per region ($5-20/month) plus cloud egress ($0.01-0.09/GB by provider). Cheap enough to include in Pro without metering at low volume; meter if abused.

## 10. Ownership

| State | Owner | Lane |
| --- | --- | --- |
| store -> exit assignment, revision, actor | daemon (profile/store record) | browser lane |
| applying it to an engine store (CEF prefs, WebKit config, headless context) | app (CEF/WebKit), browser host (headless) | browser lane |
| local egress listener (macOS app, Swift; Linux host, Rust) | browser lane; shares code shape with remote-localhost | browser lane |
| exit catalog, entitlements, KYC state, spend, usage ledger, audit rows | Cloud backend | Cloud lane |
| cmux VPN exits (VMs, keys, resolver, exit policy) | Cloud lane (image/infra) | this lane (cloud automation) for the exit image |
| vendor accounts and contracts | Lawrence (business) | n/a |
| BYO secrets | macOS Keychain (person) | app |
| egress badge, settings UI | app | browser lane |
| `browser.egress.*` protocol op + SDKs | protocol owner | browser lane |

## 11. Steps for the children

- **cx-d0d.52.2 egress core (browser lane).** Local egress listener (macOS + Linux) with peer auth, CONNECT forwarding, no fallback, byte counters; CEF per-store prefs (proxy, prediction off, WebRTC policy) and connection close on switch; headless: listener + lift the incognito/proxy refusal + E4; WebKit probe (L1-L13) and the "Open in Chromium" refusal until it passes. Red tests first for L1-L4, L11, L12 against a local canary. Exit kind `direct` and `byo-http/socks5` only (no backend).
- **cx-d0d.52.3 cmux VPN exits (Cloud lane).** Exit image (WireGuard + CONNECT proxy + resolver + range/port policy + metadata log), region catalog in the backend, key minting per device, `egress-check` echo endpoint, abuse contact and log retention (E8). Client: dial via the WireGuard hub.
- **cx-d0d.52.4 residential add-on (Cloud lane + business).** Vendor adapter (Oxylabs first), sub-user per team with limits, short-lived credential fetch for the listener, usage reconcile job, KYC gate (E9), add-on purchase and price (E10).
- **cx-d0d.52.5 BYO exits (browser lane).** Settings UI, Keychain storage, WireGuard `.conf` import, test connection with the echo endpoint, Cloud delivery of secrets (E5).
- **cx-d0d.52.6 agent control, policy, audit, badge (browser + Cloud).** `browser.egress.set/list` op + SDKs, team policy keys (7.1), rate limits (7.2), Agent activity records, the badge, metering report path and cap stop.

Order: .2 (direct + BYO HTTP/SOCKS5 proves the no-leak core), then .3 and .6 in parallel, then .4, then .5's WireGuard import.

## 12. Test plan (required CI stays fast)

- Unit (required CI, seconds): listener parsing and policy (CONNECT, refusals, no fallback, counters), pref builders, policy evaluation, op schemas, rate limiter. Plain `cargo test` of one crate and Swift package tests; no browser.
- Leak suite (not required CI; dispatch + nightly; on a Linux box and a fleet Mac, **never the laptop**): a canary stack (authoritative DNS for a test zone, STUN/TURN, HTTP/3 + WebTransport origin, WebAuthn ROR origin, an echo that records source IPs) on a dev VM; a client run per engine (headless host on a Freestyle dev clone from the image; CEF and WebKit on a fleet Mac through `cmux-ci`); packet capture on the client with a strict allow list (loopback, the exit). Each L-row in section 4 is one test with its own pass rule. A run fails on any unexplained flow.
- Exit tests (Cloud lane): exit refuses private/metadata/port 25 after resolution; resolver answers only on the tunnel; key revocation drops the tunnel.
- Metering test: a known byte volume through each kind; listener count vs vendor stats within the drift bound.
- Gate for each engine x source to appear in the UI: its leak-suite run on the current engine build passed.

## 13a. Decisions (2026-10-07)

Recorded by the coordinator (Lawrence's answers where noted); they replace the open options in section 13.

| # | Decision |
| --- | --- |
| E1 | A tab with its own egress gets its own ephemeral store. |
| E2 | A workspace egress is a derived store per profile x workspace. |
| E3 | Chromium only until our WebKit leak probe passes. |
| E4 | Headless: strict process-wide WebRTC and prediction settings. |
| E5 | Bring-your-own proxy secrets stay on this Mac only at first. |
| E6 | cmux exits are IPv4 only at first; IPv6 is blocked inside an egress store. |
| E7 | Residential (later): one sticky exit per store; never rotated for agents. |
| E8 | Exit logs: metadata only (no URLs, no bodies), 30 days, for abuse handling. |
| E12 | Chromium's own process-level traffic (updates, safe browsing) goes direct and is disclosed in the egress badge. |
| Scope | Lawrence: no residential vendor now. Ship bring-your-own proxy and cmux VPN exits only; residential (section 9, child cx-d0d.52.5) is deferred. Pricing is decided later; build metering behind a flag. |

## 13. Open decisions (options; recommendation first)

- **E1 Tab target.** (a) A tab with its own egress gets an ephemeral store (no shared cookies) - recommended; (b) drop the tab target, keep profile and workspace only; (c) per-tab proxy inside one store (not possible without a fork patch; rejected).
- **E2 Workspace target.** (a) Workspace egress = a derived store per profile x workspace (cookies split from the profile) - recommended; (b) workspace egress changes the profile's egress for all its tabs (simple, surprising).
- **E3 WebKit.** (a) Egress is Chromium-only until our WebKit probe passes; WebKit tabs get "Open in Chromium" - recommended; (b) ship WebKit with WebRTC, WebTransport, WebAuthn and prefetch disabled in egress stores and accept the unexplained later-navigation report as untested.
- **E4 Headless WebRTC/prediction.** (a) Process-wide `disable_non_proxied_udp` + prediction off for the headless host always - recommended (agents rarely need P2P; it is a stricter default, not an egress path); (b) refuse egress on headless until a per-context mechanism exists.
- **E5 BYO secrets on Cloud machines.** (a) Not supported at first: BYO exits work only for browsers on this Mac - recommended; (b) the backend stores BYO secrets encrypted (KMS, like coderouter credentials) and delivers them to the machine's host per session; (c) the Mac relays the connection (the Cloud browser's egress goes Cloud -> Mac -> BYO proxy).
- **E6 IPv6 at cmux exits.** (a) IPv4 only, resolver returns A records only - recommended for v1; (b) dual stack per exit.
- **E7 Residential session mode.** (a) Sticky per store, rotation off and never for agents - recommended; (b) rotation allowed by team policy for persons.
- **E8 Exit logs.** (a) Connection metadata (time, key, host, bytes) kept 30 days for abuse handling, no content - recommended; (b) no logs (weaker abuse response, stronger privacy claim); (c) longer retention.
- **E9 KYC for the residential add-on.** (a) Company verification (domain + payment + use-case form) before activation, mirroring vendor KYC - recommended; (b) card-only for small caps.
- **E10 Price.** (a) Residential per GB at vendor cost plus margin, with a team spend cap; VPN exits included in Pro/Max - recommended; (b) GB bundles in Max; (c) everything metered.
- **E11 First vendor.** (a) Oxylabs, Decodo second - recommended; (b) Bright Data first (strongest compliance, slower contract).
- **E12 Process-level traffic (L9).** (a) Allow direct and say so in settings - recommended; (b) block all global-context traffic while any egress store exists (breaks Safe Browsing updates and component updates).

## 14. Sources

- Repo: `plans/cmux-next/remote-localhost.md` (sections 5, 7), `plans/cmux-next/browser.md` ("Per-profile data dirs"), `Packages/macOS/CmuxNext/CEFShim/src/shim_proxy.mm`, `cmux-tui/crates/cmux-browser-host/src/cdp/driver.rs` (`create_proxy_context`), `.../headless_configure.rs`, `.../policy/egress.rs`, `.../gate/fetch.rs` (`rebinding_refusal`), `.../cdp/pipe.rs` (`default_args`), `cmux-tui/crates/cmux-remote/src/wireguard_hub.rs`, `backend/apps/api/src/egress-hosts.ts`, `.../usage-meter-do.ts`, `.../domains/team-policy.ts`, `plans/cmux-next/cloud-automation.md` section 31.
- Chromium SOCKS proxy design doc: https://www.chromium.org/developers/design-documents/network-stack/socks-proxy/
- Chromium proxy docs (QUIC proxy type): https://chromium.googlesource.com/chromium/src/+/refs/tags/78.0.3895.4/net/docs/proxy.md
- Chromium issue 40783300 (DNS prefetch leaks with a proxy): https://issues.chromium.org/issues/40783300
- Chromium issue 41345813 (disable_non_proxied_udp allows non-proxied TURN): https://issues.chromium.org/issues/41345813
- WebRtcIPHandling values: https://github.com/a8763506128977812212307169331690/WebRTC-Leak-Prevent/blob/master/DOCUMENTATION.md
- WebKit proxy leaks (mysk, 2026-08-04): https://mysk.blog/2026/08/04/webkit-proxy-icloud-private-relay-ip-leak/
- WebKit per-store proxy field report: https://github.com/theoden8/webspace_app/pull/604
- WKWebsiteDataStore header: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.h
- cmux issue 6639 (per-WebView proxy): https://github.com/manaflow-ai/cmux/issues/6639
- Oxylabs Residential Public API: https://developers.oxylabs.io/products/proxies/residential-proxies/public-api ; limits: https://developers.oxylabs.io/help-center/products-and-features/how-to-set-up-limitations ; pricing reviews: https://proxyserver.com/proxies/oxylabs-review/ , https://dataimpulse.com/blog/oxylabs-pricing-explained/
- Decodo pricing: https://decodo.com/proxies/residential-proxies/pricing ; sourcing: https://decodo.com/proxies/ethical-residential-proxy-sourcing-and-usage ; review: https://proxyway.com/reviews/smartproxy-proxies
- IPRoyal pricing: https://iproyal.com/pricing/residential-proxies/ ; sub-user API: https://docs.iproyal.com/proxies/residential/api/sub-users ; review: https://proxyway.com/reviews/iproyal-proxies
- Bright Data: KYC https://docs.brightdata.com/proxy-networks/residential/network-access ; AUP https://brightdata.com/trustcenter/acceptable-use-policy-bright-data ; partner guide https://brightdata.com/static/web/Bright-Data-Partner-Program-Guide.pdf ; pricing reviews https://proxyfacts.com/blog/bright-data-pricing
- EWDCI principles: https://ethicalwebdata.com/ewdci-our-principles/
- NetNut seizure: https://aimultiple.com/netnut-shutdown , https://hackernoon.com/what-the-netnut-takedown-reveals-about-residential-proxy-sourcing , https://www.statproxies.com/blog/netnut-seized-fbi-what-happened
