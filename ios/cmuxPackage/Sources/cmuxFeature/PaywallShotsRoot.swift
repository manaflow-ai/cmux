#if os(iOS)
// THROWAWAY (never merged): simulator screenshot harness for the paywall PR.
// Renders the real paywall, upgrade card, Cloud section and Paywall Lab over
// real BillingModel / CloudSessionController instances whose network and
// StoreKit seams return fixed data (StoreKit cannot load products on the
// fleet simulator). Slides advance on a timer so one recording captures all.
import CMUXMobileCore
import CmuxMobileBilling
import CmuxMobileBillingUI
import CmuxMobileCloud
import CmuxMobileCloudUI
import Foundation
import SwiftUI

public struct PaywallShotsRoot: View {
    @State private var index = 0
    /// A solid magenta screen between slides; the frame extractor finds
    /// slide boundaries by it, so captures carry no debug label.
    @State private var showsMarker = true

    public init() {}

    static let slides: [ShotSlide] = {
        var slides: [ShotSlide] = []
        let layouts: [BillingPaywallLayout] = [.cards, .comparison, .focus, .checklist, .planTabs, .hero, .specList, .trialTimeline]
        for layout in layouts {
            for angle in ShotAngle.allCases {
                slides.append(ShotSlide(
                    name: "\(layout.rawValue)-\(angle.rawValue)-dark-default",
                    scheme: .dark, surface: .settings,
                    sheet: .init(layout: layout, angle: angle, trial: layout == .trialTimeline)
                ))
            }
        }
        slides.append(ShotSlide(name: "cards-outcome-light-default", scheme: .light, surface: .settings,
                                sheet: .init(layout: .cards, angle: .outcome)))
        slides.append(ShotSlide(name: "specList-compute-light-default", scheme: .light, surface: .settings,
                                sheet: .init(layout: .specList, angle: .compute)))
        slides.append(ShotSlide(name: "headline-locked_vm_size-planTabs-dark-default", scheme: .dark, surface: .cloud,
                                sheet: .init(layout: .planTabs, angle: .compute), entry: .lockedMachineSize))
        slides.append(ShotSlide(name: "headline-cloud_new_machine-cards-dark-default", scheme: .dark, surface: .cloud,
                                sheet: .init(layout: .cards, angle: .outcome), entry: .cloudNewMachine))
        slides.append(ShotSlide(name: "entry-settings-card-dark-default", scheme: .dark, surface: .settings))
        slides.append(ShotSlide(name: "entry-settings-card-light-default", scheme: .light, surface: .settings))
        slides.append(ShotSlide(name: "entry-cloud-banner-dark-default", scheme: .dark, surface: .cloud))
        slides.append(ShotSlide(name: "cards-trial-dark-default", scheme: .dark, surface: .settings,
                                sheet: .init(layout: .cards, angle: .outcome, trial: true)))
        slides.append(ShotSlide(name: "not-eligible-web-dark-default", scheme: .dark, surface: .settings,
                                sheet: .init(layout: .cards, angle: .outcome, eligible: false)))
        slides.append(ShotSlide(name: "paywall-lab-dark-default", scheme: .dark, surface: .lab))
        slides.append(ShotSlide(name: "cards-outcome-dark-ax2", scheme: .dark, surface: .settings,
                                sheet: .init(layout: .cards, angle: .outcome), dynamicType: .accessibility2))
        slides.append(ShotSlide(name: "checklist-compute-dark-ax2", scheme: .dark, surface: .settings,
                                sheet: .init(layout: .checklist, angle: .compute), dynamicType: .accessibility2))
        return slides
    }()

    public var body: some View {
        let slide = Self.slides[min(index, Self.slides.count - 1)]
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if showsMarker {
                Color(red: 1, green: 0, blue: 1).ignoresSafeArea()
            } else {
                ShotSlideView(slide: slide)
            }
        }
        .id("\(index)-\(showsMarker)")
        .preferredColorScheme(slide.scheme)
        .task {
            // Pacing for the recording only; this harness is never merged.
            for next in Self.slides.indices {
                index = next
                showsMarker = true
                try? await Task.sleep(for: .seconds(1.2))
                showsMarker = false
                try? await Task.sleep(for: .seconds(6))
            }
            showsMarker = true
        }
    }
}

enum ShotAngle: String, CaseIterable {
    case outcome
    case compute
}

struct ShotSheet {
    var layout: BillingPaywallLayout
    var angle: ShotAngle
    var trial = false
    var eligible = true
}

struct ShotSlide {
    enum Surface { case settings, cloud, lab }

    let name: String
    let scheme: ColorScheme
    let surface: Surface
    var sheet: ShotSheet? = nil
    var entry: BillingEntryPoint = .settingsUpgradeCard
    var dynamicType: DynamicTypeSize = .large
}

struct ShotSlideView: View {
    let slide: ShotSlide
    @State private var model: BillingModel
    @State private var cloud: CloudSessionController?
    @State private var sheetShown = false

    init(slide: ShotSlide) {
        self.slide = slide
        let sheet = slide.sheet
        let config = sheet.map { ShotFixtures.config(layout: $0.layout, angle: $0.angle) } ?? .control
        _model = State(initialValue: BillingModel(
            api: ShotBillingAPI(config: config, trial: sheet?.trial ?? false, eligible: sheet?.eligible ?? true, staff: true),
            store: ShotStoreKit(),
            analytics: nil,
            trialProver: sheet?.trial == true ? ShotProver() : nil
        ))
        if slide.surface == .cloud {
            _cloud = State(initialValue: CloudSessionController(
                service: ShotCloudService(),
                identityStore: ShotIdentityStore(),
                tunnelStarter: ShotTunnelStarter(),
                connector: ShotConnector(),
                stateDirectory: FileManager.default.temporaryDirectory,
                deviceName: "iPhone"
            ))
        }
    }

    var body: some View {
        content
            .sheet(isPresented: $sheetShown) {
                NavigationStack {
                    MobilePaywallView(entryPoint: slide.entry)
                }
                .environment(model)
                .dynamicTypeSize(slide.dynamicType)
            }
            .task {
                await model.loadIfNeeded()
                if slide.sheet != nil { sheetShown = true }
            }
            .environment(model)
            .dynamicTypeSize(slide.dynamicType)
    }

    @ViewBuilder
    private var content: some View {
        switch slide.surface {
        case .settings:
            NavigationStack {
                Form {
                    MobileSettingsUpgradeSection()
                    Section {
                        LabeledContent("Signed in as", value: "you@example.com")
                        Text("Sign Out").foregroundStyle(.red)
                    } header: { Text("Account") }
                    MobileSettingsPlanSection()
                    Section {
                        Label("What's New", systemImage: "megaphone")
                        Label("Terminal Shortcuts", systemImage: "keyboard")
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
            }
        case .cloud:
            if let cloud {
                NavigationStack {
                    CloudSectionView(controller: cloud)
                }
                .task { cloud.refreshMachines() }
            }
        case .lab:
            NavigationStack {
                MobilePaywallLabView()
            }
        }
    }
}

enum ShotFixtures {
    static let headlines = [
        "locked_vm_size": "Run bigger machines",
        "cloud_new_machine": "Start your first Cloud machine",
        "limit": "You reached your plan's limit",
    ]

    static func config(layout: BillingPaywallLayout, angle: ShotAngle) -> BillingPaywallConfig {
        let headline: String
        let subheadline: String
        let bullets: [String]
        switch angle {
        case .outcome:
            headline = layout == .hero
                ? "Agents keep working while your Mac sleeps"
                : "Run coding agents in the cloud, reach them from your iPhone"
            subheadline = "Persistent Cloud VMs keep working when you close your laptop."
            bullets = layout == .focus || layout == .cards ? [
                "Terminals keep running when you close your laptop",
                "Agents clone repos, run commands and open pull requests",
                "Check in from the iOS app",
            ] : []
        case .compute:
            headline = layout == .trialTimeline ? "Try Pro free for 7 days" : "More cloud compute"
            subheadline = "Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM on Pro."
            bullets = layout == .focus ? [
                "On Pro one VM can have up to 8 vCPUs and 16 GB RAM",
                "Max shares 80 vCPUs and 160 GB RAM",
            ] : []
        }
        return BillingPaywallConfig(
            experiment: "ios-paywall-v1", variant: "\(layout.rawValue)-\(angle.rawValue)", layout: layout,
            headline: headline, subheadline: subheadline, bullets: bullets,
            highlightedPlanID: .pro, defaultBillingPeriod: .monthly, ctaStyle: .price,
            showYearlySavings: true, entryPointHeadlines: headlines
        )!
    }

    static func config(layout: BillingPaywallLayout) -> BillingPaywallConfig {
        config(layout: layout, angle: .outcome)
    }
}

struct ShotBillingAPI: BillingAPI {
    let config: BillingPaywallConfig
    let trial: Bool
    let eligible: Bool
    let staff: Bool

    func accountToken() async throws -> BillingAccount {
        BillingAccount(
            appAccountToken: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            eligible: eligible,
            reason: eligible ? nil : .stripeSubscriptionActive,
            currentPlan: BillingCurrentPlan(planID: .free, source: .none),
            products: eligible ? ShotStoreKit.references : [],
            paywall: config,
            trial: trial ? BillingTrialOffer(
                offered: true, planID: .pro, billingPeriod: .monthly,
                productID: "com.cmux.app.pro.trial.monthly", attestRequired: true,
                limits: BillingTrialLimits(machines: 1, vcpus: 2, memoryGb: 4, vmHours: 20)
            ) : nil,
            staff: staff
        )
    }

    func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt {
        throw URLError(.notConnectedToInternet)
    }

    func trialChallenge() async throws -> String { "challenge" }

    func verifyTrial(_ request: BillingTrialVerifyRequest) async throws -> BillingTrialVerification {
        BillingTrialVerification(eligible: true, introductoryOfferJWS: "jws", legacyTrialAllowed: true, reason: nil)
    }

    func paywallVariants() async throws -> [BillingPaywallVariant] {
        [
            BillingPaywallVariant(status: "live", config: .control),
            BillingPaywallVariant(status: "live", config: ShotFixtures.config(layout: .comparison)),
            BillingPaywallVariant(status: "live", config: ShotFixtures.config(layout: .focus)),
            BillingPaywallVariant(status: "retired", config: BillingPaywallConfig(
                experiment: "ios-paywall-v0", variant: "plain", layout: .cards, headline: "Plans",
                subheadline: "", bullets: [], highlightedPlanID: nil, defaultBillingPeriod: .monthly,
                ctaStyle: .price, showYearlySavings: false
            )!),
        ]
    }
}

struct ShotProver: BillingTrialDeviceProving {
    var isSupported: Bool { true }
    func proof(clientData: Data) async throws -> BillingTrialDeviceProof {
        BillingTrialDeviceProof(keyID: "k", attestation: "a", assertion: nil, deviceCheckToken: "t")
    }
    func resetKey() async {}
}

/// USD prices of the App Store products, as the USA storefront shows them.
struct ShotStoreKit: StoreKitClient {
    static let references: [BillingProductReference] = [
        BillingProductReference(productID: "com.cmux.app.go.monthly", planID: .go),
        BillingProductReference(productID: "com.cmux.app.pro.monthly", planID: .pro),
        BillingProductReference(productID: "com.cmux.app.pro.yearly", planID: .pro),
        BillingProductReference(productID: "com.cmux.app.max.monthly", planID: .max),
    ]

    private static let prices: [String: (Decimal, Bool)] = [
        "com.cmux.app.go.monthly": (14.99, false),
        "com.cmux.app.pro.monthly": (74.99, false),
        "com.cmux.app.pro.yearly": (699.99, true),
        "com.cmux.app.max.monthly": (299.99, false),
        "com.cmux.app.pro.trial.monthly": (74.99, false),
    ]

    func products(for ids: [String]) async throws -> [StoreProduct] {
        let style = Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US"))
        return ids.compactMap { id in
            guard let (price, yearly) = Self.prices[id] else { return nil }
            return StoreProduct(
                id: id,
                displayName: id,
                productDescription: "",
                displayPrice: price.formatted(style),
                periodUnitName: yearly ? "year" : "month",
                price: price,
                currencyCode: "USD",
                monthlyEquivalentDisplayPrice: yearly ? (price / 12).formatted(style) : nil,
                introductoryOffer: id.contains(".trial.")
                    ? StoreIntroductoryOffer(periodValue: 7, periodUnit: .day, periodCount: 1, isFreeTrial: true, isEligibleOnDevice: true)
                    : nil
            )
        }
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> StorePurchaseResult { .userCancelled }
    func transactionUpdates() -> AsyncStream<StoreTransactionVerification> { AsyncStream { _ in } }
    func unfinishedTransactions() async -> [StoreTransactionVerification] { [] }
    func currentEntitlements() async -> [StoreTransactionVerification] { [] }
    func syncWithAppStore() async throws {}
    func storefrontCountryCode() async -> String? { "USA" }
    func finish(transactionID: UInt64) async {}
}

struct ShotFailure: Error {}

struct ShotCloudService: CloudVMServing {
    func listMachines() async throws -> [CloudMachine] { [] }
    func listMachineCatalog() async throws -> CloudMachineCatalog {
        CloudMachineCatalog(
            machines: [],
            availableKinds: nil,
            limits: CloudMachineLimits(maxActiveMachines: 0, activeMachineCount: 0, planID: "free", memoryOptionsMb: [8192])
        )
    }
    func createMachine(options: CloudMachineCreateOptions, idempotencyKey: String) async throws -> CloudMachine { throw ShotFailure() }
    func enrollTunnel(clientPublicKey: String, deviceFingerprint: String, tunnelPurpose: CloudTunnelPurpose, deviceName: String?) async throws
        -> CloudTunnelEnrollment { throw ShotFailure() }
    func enrollTunnel(
        clientPublicKey: String,
        deviceFingerprint: String,
        tunnelPurpose: CloudTunnelPurpose,
        deviceName: String?,
        credentials: CloudAPITokenSource.TokenContext?
    ) async throws -> CloudTunnelEnrollment { throw ShotFailure() }
    func revokeTunnel(deviceFingerprint: String, tunnelPurpose: CloudTunnelPurpose) async throws {}
    func revokeTunnel(deviceFingerprint: String, tunnelPurpose: CloudTunnelPurpose, accessToken: String, refreshToken: String) async throws {}
    func revokeTunnel(
        deviceFingerprint: String,
        tunnelPurpose: CloudTunnelPurpose,
        accessToken: String,
        refreshToken: String,
        teamID: String?
    ) async throws {}
    func openAttach(machineID: String, deviceFingerprint: String) async throws -> CloudAttachEndpoint { throw ShotFailure() }
    func approveEnrollment(machineID: String, invitationId: String) async throws -> Bool { false }
    func pauseMachine(id: String) async throws {}
    func resumeMachine(id: String) async throws {}
    func restartMachine(id: String) async throws {}
    func deleteMachine(id: String) async throws {}
}

struct ShotIdentityStore: CloudDeviceIdentityStoring {
    func read() async -> CloudDeviceIdentityReadResult { .absent }
    func resolve() async throws -> CloudDeviceIdentity { throw ShotFailure() }
    func write(_ identity: CloudDeviceIdentity) async throws {}
}

struct ShotTunnelStarter: CloudTunnelStarting {
    func start(wgQuickConfig: String) async throws -> any CloudTunnel { throw ShotFailure() }
}

struct ShotConnector: CloudTerminalConnecting {
    func connect(
        route: String,
        stateDirectory: URL,
        deviceName: String,
        invitation: String?,
        trustedCarrier: Bool,
        tunnel: (any CloudTunnel)?
    ) async throws -> any CloudTerminalSession { throw ShotFailure() }
}
#endif
