# AI Provider Accounts

cmux's sidebar footer and Settings pane support one or more AI provider accounts through a generic `UsageProvider` abstraction. Each provider contributes:

- credential fields (session key, API key, org id, …)
- a usage endpoint that returns a session (5h) + week (7d) utilization window
- an optional status-page endpoint

The UI, store, controller, polling, popover, Settings card, editor sheet, and color thresholds are all shared — a new provider is a ~60-line file.

## File layout

```text
Sources/Providers/
├── UsageProvider.swift               — types: UsageProvider, CredentialField, ProviderUsageWindow(s), ProviderIncident, ProviderUsageSnapshot
├── ProviderAccount.swift             — ProviderAccount, ProviderSecret, ProviderAccountStoreError
├── ProviderAccountStore.swift        — generic Keychain + UserDefaults store (singleton)
├── ProviderAccountsController.swift  — generic polling controller (singleton)
├── ProviderRegistry.swift            — Providers namespace + registry (all / ui)
├── ProviderISO8601DateParser.swift   — shared ISO8601 date parser
└── <Name>Provider.swift             — per-provider definition (e.g. ClaudeProvider, CodexProvider)
```

## Adding a new provider (three files)

1. **Write `Sources/Providers/<Name>Provider.swift`** — extend the `Providers` namespace with a `UsageProvider` value:

   ```swift
   extension Providers {
       static let myProvider = UsageProvider(
           id: "myprovider",
           displayName: "MyProvider",
           keychainService: "com.cmuxterm.app.myprovider-accounts",
           credentialFields: [
               CredentialField(
                   id: "apiKey",
                   label: String(localized: "providers.myprovider.apiKey.label", defaultValue: "API key"),
                   placeholder: "sk-…",
                   isSecret: true,
                   helpText: nil,
                   validate: { !$0.isEmpty }
               ),
           ],
           statusPageURL: URL(string: "https://status.myprovider.com/"),
           statusSectionTitle: String(localized: "myprovider.accounts.status.section", defaultValue: "MyProvider status"),
           helpDocURL: URL(string: "https://github.com/manaflow-ai/cmux/blob/main/docs/usage-monitoring-setup.md#myprovider"),
           fetchUsage: { secret in
               // HTTPS call + JSON parsing → ProviderUsageWindows
           },
           fetchStatus: nil
       )
   }
   ```

2. **Register it in `Sources/Providers/ProviderRegistry.swift`** by adding it to `ProviderRegistry.all`. `ProviderRegistry.ui` automatically filters out providers whose `credentialFields` is empty, so a work-in-progress stub stays hidden until it's ready.

3. **Add a `## <Name>` section to [`docs/usage-monitoring-setup.md`](usage-monitoring-setup.md)** explaining how an end-user obtains the credential values. Use the existing Claude and Codex sections as templates; the `helpDocURL` in step 1 resolves to that section's anchor, so the "Setup instructions" button in the editor sheet will 404 without it.

Everything else — the collapsible sidebar section, pace tick, popover, Add/Edit sheet with dynamic fields, Settings card, color thresholds, polling, occlusion gating — is reused automatically.

## Data contract

`fetchUsage` must return `ProviderUsageWindows` containing two `ProviderUsageWindow` values:

| Window  | `windowSeconds` | Meaning                           |
|---------|-----------------|-----------------------------------|
| session | `18_000`        | 5-hour rolling window utilization |
| week    | `604_800`       | 7-day rolling window utilization  |

`utilization` is an integer 0–100 representing **percent used** (not percent remaining). If the upstream API returns "% left", invert it at parse time (`100 - x`).
