# Native v2 integration

The iOS app now owns one shared `V2ControlService` for the selected Stack account and team. Every callback checks the captured account/team generation; switching away and back cannot revive older work. Stack sign-in persistence remains owned by AuthCoordinator.

The v2 device identifier, signing key, cached credentials, directory, paired Mac database and local paths use fresh namespaces. No v1 identity, credential, device-list or paired-Mac cache is imported. The prior iOS backend composition, discovery broker, presence client, registration retries and runtime fallback switch are removed from app composition. The unrelated push-reply backend still uses the existing service-origin helper.

Cached valid credentials start IROH endpoint work in parallel with backend setup. Ticket and relay replacement update the control session and relay configuration in place. Returning to the foreground checks the control socket independently of the shell's live RPC probe; elapsed time alone does not replace a healthy IROH session.

The control service owns ordered sends, its receive loop, request deadlines, reconnects, bounded delivery acknowledgements and per-method cooldowns. HTTP recovery uses only v2 routes and preserves an uncertain operation's request ID. Each proof uses a fresh nonce, and each local request attempt has a separate completion fence. Incoming revocation removes authority and closes affected peer sessions. Protocol close reasons preserve permanent versus retryable outcomes.

Directory pagination pins the first page's revision and retries if it changes. It merges outbound devices and target-specific inbound permissions separately, with at most 4096 entries in each list; missing inbound permissions grant no access. No partial list is published. The list contains only permitted, pairing-enabled Macs. Client compatibility checks receive the existing `mac:` namespace prefix as a local projection; canonical identities and signatures retain the raw bundle namespace.

Explicit local direct connections use IP addresses with required ports, stored only on the iPhone. Iroh's current FFI configures relay policy per endpoint, so iOS lazily creates a second, relay-disabled endpoint when a user selects direct mode. It uses the same installation key because both transports represent the same enrolled device/build tuple. Different tuples always have different keys. This direct endpoint needs no relay credential or relay readiness and cannot gain relays during renewal. Automatic IROH connections keep their original endpoint and authenticated direct-path upgrades. Account/team teardown fences and closes both endpoint owners.

The journal records launch, cached endpoint readiness, control startup, directory installation, admitted sessions, background/foreground gaps and credential installation. `admittedSessions` is a cumulative admission counter for the runtime, not a claim that all recorded sessions remain open.

Onboarding and empty-list copy explain enabling iOS pairing in Mac settings and selecting the same team. Direct-address fields show explicit ports and local storage. All eight new keys have English, German, French, Arabic, Spanish, Traditional/Simplified Chinese, Korean and Japanese entries. Apple onboarding and text-field guidance was checked, with no chosen deviation:

- https://developer.apple.com/design/human-interface-guidelines/onboarding
- https://developer.apple.com/design/human-interface-guidelines/text-fields

Two existing ShellUI test problems blocked compiling its test target: an exact duplicate test declaration crashed Swift 6.2.4, and a lock-protected static mutable request counter lacked compiler-visible isolation. The duplicate was removed and the counter moved into `Synchronization.Mutex`; push-reply runtime behavior was unchanged.

Live Mac-to-iPhone acceptance, App Store signing and relay-renewal/background soaks remain with the parent integration task. Compilation and isolated protocol tests do not establish those outcomes.
