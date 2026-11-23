// l10n-allow-file: debug fixture messages, not shipped UI.
// A reply with a ```mermaid chart, for `debug.agent_pane seed_rows` with `fixture: "mermaid"`: a
// capture shows the chart drawn in the real app's chat (user, Nov 20: the nightly's chat showed
// "Couldn't draw this chart" and the raw source instead). The chart is the user's, as in
// webviews/test/fixtures/mermaid-front-door.mmd.
import type { AcpmuxRow } from "./model";

const CHART = `flowchart LR
    Slack([Slack events]) --> CS

    subgraph Write path
        CS[Connector-service<br/>encrypt-only grant] -->|"encrypt(text, ctx)"| CrW[Cryptor sidecar]
        CrW -->|ciphertext| CS
    end

    CS -->|"enc:v1 record, TTL 72h<br/>ctx = {cloudId, channelId, ts}"| R[(Redis<br/>per region)]

    subgraph Read path - the only front door
        RS[Slack Message Read Service<br/>prod only, decrypt grant] -->|read records| R
        RS -->|"decrypt + check ctx"| CrR[Cryptor sidecar]
        CrR --> KMS[(KMS key<br/>dedicated, per region)]
        RS -.->|log each decrypt| Audit[[Audit logs + alerts]]
    end

    Caller([API caller<br/>UCT + Slack token + channel access]) -->|authenticated read| RS
    RS -->|plaintext| Caller

    X1[Direct Redis read / dump]:::blocked -.->|ciphertext only| R
    X2[Other services]:::blocked -.->|no grant| KMS
    X3[Staging / laptop / service assume]:::blocked -.->|separate keys, denied| KMS
    X4[Connector-service decrypt]:::blocked -.->|encrypt-only, S3 export off| KMS
    A1[Platform admins]:::accepted -.->|full KMS access| KMS
    A2[Data key in sidecar memory]:::accepted -.-> CrW

    classDef blocked fill:#fde2e2,stroke:#c0392b,color:#7b241c
    classDef accepted fill:#fff4d6,stroke:#d4a017,color:#7d6608`;

export function mermaidRows(at: number): AcpmuxRow[] {
  return [
    { id: "mermaid-ask", version: 1, at, kind: "user", text: "Draw the front door and back doors" },
    {
      id: "mermaid-reply",
      version: 1,
      at: at + 4_000,
      kind: "assistant",
      text:
        "**Diagram: front door, back doors**\n\n```mermaid\n" +
        CHART +
        "\n```\n\nRed means blocked and yellow means an accepted risk.",
    },
    { id: "mermaid-summary", version: 1, at: at + 4_000, kind: "turnSummary", durationMs: 4_000, toolCount: 0 },
  ] as AcpmuxRow[];
}
