#if DEBUG && os(iOS)
import CmuxNextTransport
import SwiftUI

/// Graduation P4 slice 3 UI: the dev dial surface for the parallel
/// next-transport host. Launched exactly like the other Debug alternate
/// roots (CMUXMobileRootScene): CMUX_NEXT_TRANSPORT_DEV=1. Standard Form
/// per HIG Lists-and-tables; DEBUG builds only.
///
/// Flow mirrors the lab app: paste the Mac's ticket + grant (from the
/// `next_transport_ticket` / `next_transport_grant` socket verbs), Connect,
/// then Run Echo for the 50-chunk checksummed proof.
struct NextTransportDevScreen: View {
    @State private var client = NextTransportDialClient()
    @State private var ticketJSON = ""
    @State private var grantJSON = ""
    @State private var configureNote: String?
    // Default OFF: routing over the next transport is a dev opt-in.
    @AppStorage(NextTransportGraduationFacade.routeTrafficDefaultsKey)
    private var routeAppTraffic = false

    var body: some View {
        NavigationStack {
            Form {
                Section(
                    String(
                        localized: "nextTransport.dev.routing",
                        defaultValue: "App traffic")
                ) {
                    Toggle(
                        String(
                            localized: "nextTransport.dev.routeAppTraffic",
                            defaultValue: "Route cmux over next transport"),
                        isOn: $routeAppTraffic)
                    Text(
                        String(
                            localized: "nextTransport.dev.routeAppTraffic.detail",
                            defaultValue:
                                "Off by default. When enabled, app launches bootstrap over the paired channel, then carry control, terminals, and events on the next transport for Macs that support it. A credential denial falls back to the paired channel and re-pairs."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section(
                    String(
                        localized: "nextTransport.dev.identity",
                        defaultValue: "This phone")
                ) {
                    LabeledContent(
                        String(
                            localized: "nextTransport.dev.deviceID",
                            defaultValue: "Device ID")
                    ) {
                        Text(client.deviceID.prefix(13) + "…")
                            .font(.caption.monospaced())
                    }
                    Button(
                        String(
                            localized: "nextTransport.dev.copyKey",
                            defaultValue: "Copy public key")
                    ) {
                        UIPasteboard.general.string = client.devicePublicKeyB64
                    }
                }

                Section(
                    String(
                        localized: "nextTransport.dev.setup",
                        defaultValue: "Mac ticket + grant")
                ) {
                    TextField(
                        String(
                            localized: "nextTransport.dev.ticket",
                            defaultValue: "Ticket JSON"),
                        text: $ticketJSON, axis: .vertical
                    )
                    .font(.caption.monospaced())
                    .lineLimit(2...4)
                    TextField(
                        String(
                            localized: "nextTransport.dev.grant",
                            defaultValue: "Grant JSON"),
                        text: $grantJSON, axis: .vertical
                    )
                    .font(.caption.monospaced())
                    .lineLimit(2...4)
                    Button(
                        String(
                            localized: "nextTransport.dev.configure",
                            defaultValue: "Configure")
                    ) {
                        do {
                            try client.configure(
                                ticketJSON: ticketJSON, grantJSON: grantJSON)
                            configureNote = nil
                        } catch {
                            // Short stable code only; the full error is in
                            // os.log via the client.
                            configureNote = String(
                                localized: "nextTransport.dev.configure.rejected",
                                defaultValue:
                                    "Rejected: \(nextTransportShortErrorCode(error))")
                        }
                    }
                    .disabled(ticketJSON.isEmpty || grantJSON.isEmpty)
                    if let configureNote {
                        Text(configureNote)
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                    }
                }

                Section(
                    String(
                        localized: "nextTransport.dev.session",
                        defaultValue: "Session")
                ) {
                    LabeledContent(
                        String(
                            localized: "nextTransport.dev.state",
                            defaultValue: "State")
                    ) {
                        Text(client.state)
                            .bold()
                            .foregroundStyle(client.dialState == .ready ? .green : .primary)
                    }
                    if let denial = client.lastDenial {
                        LabeledContent(
                            String(
                                localized: "nextTransport.dev.lastDenial",
                                defaultValue: "Last denial")
                        ) {
                            Text(denial.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                        }
                    }
                    Button(
                        String(
                            localized: "nextTransport.dev.connect",
                            defaultValue: "Connect")
                    ) {
                        Task { await client.connect() }
                    }
                    Button(
                        String(
                            localized: "nextTransport.dev.disconnect",
                            defaultValue: "Disconnect"),
                        role: .destructive
                    ) {
                        Task { await client.disconnect() }
                    }
                    Button(
                        String(
                            localized: "nextTransport.dev.echo",
                            defaultValue: "Run echo (50 chunks)")
                    ) {
                        Task { await client.runEcho() }
                    }
                    .disabled(client.dialState != .ready)
                    if let verdict = client.echoVerdict {
                        Text(verdict)
                            .font(.caption.monospaced())
                            .foregroundStyle(verdict.hasPrefix("CLEAN") ? .green : .orange)
                    }
                }

                Section(
                    String(
                        localized: "nextTransport.dev.events",
                        defaultValue: "Events")
                ) {
                    ForEach(Array(client.events.suffix(40).enumerated().reversed()), id: \.offset) {
                        _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(
                String(
                    localized: "nextTransport.dev.title",
                    defaultValue: "Next Transport (dev)")
            )
        }
    }
}
#endif
