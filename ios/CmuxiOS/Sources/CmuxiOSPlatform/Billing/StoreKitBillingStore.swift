public import CmuxiOSFeatureKit
import Foundation

#if canImport(StoreKit) && os(iOS)
import StoreKit

/// StoreKit 2 implementation of the platform billing seam.
///
/// The actor owns the product cache, entitlement projection and transaction
/// listener.  Transactions are finished only after the injected billing owner
/// accepts their verified JWS.  This makes an interrupted owner request safe:
/// StoreKit will deliver the transaction again on the next launch instead of
/// silently dropping an entitlement.
public actor StoreKitBillingStore: BillingStore {
    public let configuration: StoreKitBillingConfiguration

    private let transactionSink: (any BillingTransactionSubmitting)?
    private let fallback: (any BillingStore)?
    private var subscribers: [UUID: AsyncStream<SourceSnapshot<BillingState>>.Continuation] = [:]
    private var state: BillingState
    private var connection: SourceConnection = .connecting
    private var revision: UInt64 = 0
    private var products: [String: Product] = [:]
    private var entitlements: [String: BillingEntitlement] = [:]
    private var started = false
    private var startTask: Task<Void, Never>?
    private var transactionTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var usingFallback = false
    private var operationActive = false

    public init(
        configuration: StoreKitBillingConfiguration,
        transactionSink: (any BillingTransactionSubmitting)? = nil,
        fallback: (any BillingStore)? = nil
    ) {
        self.configuration = configuration
        self.transactionSink = transactionSink
        self.fallback = fallback
        self.state = BillingState(plans: [], currentPlanID: nil)
    }

    deinit {
        transactionTask?.cancel()
        fallbackTask?.cancel()
    }

    public func updates() async -> AsyncStream<SourceSnapshot<BillingState>> {
        await ensureStarted()
        let (updates, continuation) = AsyncStream.makeStream(
            of: SourceSnapshot<BillingState>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(snapshot)
        return updates
    }

    public func purchase(_ planID: String, key: IntentKey) async throws -> IntentReceipt {
        await ensureStarted()
        if usingFallback, let fallback { return try await fallback.purchase(planID, key: key) }
        guard !operationActive else { return .refused(key: key, reason: StoreKitBillingError.operationInProgress.userMessage) }
        guard connection.isLive else { return .refused(key: key, reason: StoreKitBillingError.unavailable.userMessage) }
        guard let product = products[planID] else { return .refused(key: key, reason: StoreKitBillingError.productNotFound.userMessage) }

        operationActive = true
        state.phase = .purchasing(planID: planID)
        publish()
        defer {
            operationActive = false
            if case .purchasing = state.phase { state.phase = .idle; publish() }
        }

        do {
            switch try await product.purchase() {
            case .success(let result):
                return await accept(result, key: key, requireOwner: true)
            case .userCancelled:
                return .refused(key: key, reason: StoreKitBillingError.cancelled.userMessage)
            case .pending:
                return .refused(key: key, reason: StoreKitBillingError.pending.userMessage)
            @unknown default:
                return .refused(key: key, reason: StoreKitBillingError.unknown.userMessage)
            }
        } catch {
            let mapped = BillingErrorMapper.map(error)
            return .refused(key: key, reason: mapped.userMessage)
        }
    }

    public func restore(key: IntentKey) async throws -> IntentReceipt {
        await ensureStarted()
        if usingFallback, let fallback { return try await fallback.restore(key: key) }
        guard !operationActive else { return .refused(key: key, reason: StoreKitBillingError.operationInProgress.userMessage) }
        guard connection.isLive else { return .refused(key: key, reason: StoreKitBillingError.unavailable.userMessage) }

        operationActive = true
        state.phase = .restoring
        publish()
        defer {
            operationActive = false
            if state.phase == .restoring { state.phase = .idle; publish() }
        }

        do {
            try await AppStore.sync()
        } catch {
            return .refused(key: key, reason: BillingErrorMapper.map(error).userMessage)
        }

        var lastRevision = revision
        var hadEntitlement = false
        do {
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                hadEntitlement = true
                let transactionKey = Self.transactionKey(base: key, transactionID: String(transaction.id))
                let receipt = await accept(result, key: transactionKey, requireOwner: transactionSink != nil)
                switch receipt {
                case .committed(_, let revision): lastRevision = max(lastRevision, revision)
                case .refused(_, let reason):
                    return .refused(key: key, reason: reason)
                }
            }
        }
        state.currentPlanID = BillingStateProjection.currentPlanID(from: entitlements.values)
        publish()
        // A restore with no active entitlement is still a successful, idempotent
        // owner operation; the UI can continue to show the available plans.
        _ = hadEntitlement
        return .committed(key: key, revision: lastRevision)
    }

    private var snapshot: SourceSnapshot<BillingState> {
        SourceSnapshot(revision: revision, value: state, connection: connection)
    }

    private func ensureStarted() async {
        if let startTask {
            await startTask.value
            return
        }
        guard !started else { return }
        started = true
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.loadStore()
        }
        startTask = task
        await task.value
    }

    private func loadStore() async {
        guard !configuration.productIDs.isEmpty else {
            await activateFallbackOrUnavailable(reason: .notConfigured)
            return
        }
        transactionTask = Task { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                await self.handleTransactionUpdate(result)
            }
        }
        do {
            let loaded = try await Product.products(for: configuration.productIDs)
            guard !loaded.isEmpty else {
                await activateFallbackOrUnavailable(reason: .productNotFound)
                return
            }
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            state.plans = loaded.sorted { $0.id < $1.id }.map {
                BillingPlan(id: $0.id, name: $0.displayName, displayPrice: $0.displayPrice, summary: $0.description)
            }
            await refreshEntitlements()
            connection = .live(path: "storekit")
            state.phase = .idle
            publish()
        } catch {
            // A network failure must remain visible as offline.  A DEBUG build
            // may use canned plans only when StoreKit has no products at all;
            // this avoids masking a live outage with misleading sample data.
            if BillingErrorMapper.map(error) == .productNotFound {
                await activateFallbackOrUnavailable(reason: .productNotFound)
            } else {
                connection = .offline(reason: BillingErrorMapper.map(error).userMessage)
                state.phase = .idle
                publish()
            }
        }
    }

    private func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            record(entitlement: Self.entitlement(from: transaction))
        }
        state.currentPlanID = BillingStateProjection.currentPlanID(from: entitlements.values)
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        record(entitlement: Self.entitlement(from: transaction))
        state.currentPlanID = BillingStateProjection.currentPlanID(from: entitlements.values)
        publish()
        // Updates that arrive outside an explicit purchase (for example a
        // renewal) still have to reach the owner.  Keep the transaction
        // unfinished when the owner is unavailable so it is retried next run.
        guard transactionSink != nil else { return }
        let key = Self.transactionKey(base: IntentKey(rawValue: "storekit-update"), transactionID: String(transaction.id))
        _ = await accept(result, key: key, requireOwner: true)
    }

    private func accept(_ result: VerificationResult<Transaction>, key: IntentKey, requireOwner: Bool) async -> IntentReceipt {
        guard case .verified(let transaction) = result else {
            return .refused(key: key, reason: StoreKitBillingError.verificationFailed.userMessage)
        }
        let value = Self.value(from: result, transaction: transaction)
        record(entitlement: Self.entitlement(from: transaction))
        state.currentPlanID = BillingStateProjection.currentPlanID(from: entitlements.values)
        publish()

        guard let transactionSink else {
            if requireOwner { return .refused(key: key, reason: StoreKitBillingError.ownerUnavailable.userMessage) }
            return .committed(key: key, revision: revision)
        }
        do {
            let ownerReceipt = try await transactionSink.submit(value, key: key)
            if let ownerPlan = ownerReceipt.currentPlanID { state.currentPlanID = ownerPlan }
            await transaction.finish()
            publish()
            return .committed(key: key, revision: ownerReceipt.revision)
        } catch {
            let mapped = BillingErrorMapper.map(error)
            return .refused(key: key, reason: mapped == .unknown ? StoreKitBillingError.ownerUnavailable.userMessage : mapped.userMessage)
        }
    }

    private func record(entitlement: BillingEntitlement) {
        guard let existing = entitlements[entitlement.productID], existing.purchasedAt > entitlement.purchasedAt else {
            entitlements[entitlement.productID] = entitlement
            return
        }
        // A late renewal/revocation for an older transaction cannot roll back
        // the newest entitlement.
    }

    private func activateFallbackOrUnavailable(reason: StoreKitBillingError) async {
        guard configuration.fallbackToMockWhenUnavailable, let fallback else {
            connection = .offline(reason: reason.userMessage)
            state.phase = .idle
            publish()
            return
        }
        usingFallback = true
        let updates = await fallback.updates()
        var iterator = updates.makeAsyncIterator()
        // Await the fallback's initial snapshot before returning from
        // `updates()`, so a plans screen never renders a transient empty
        // StoreKit state while the DEBUG mock is being selected.
        if let first = await iterator.next() { adoptFallback(first) }
        fallbackTask = Task { [weak self] in
            while let update = await iterator.next() {
                await self?.adoptFallback(update)
            }
        }
    }

    private func adoptFallback(_ update: SourceSnapshot<BillingState>) {
        state = update.value
        connection = update.connection
        revision = max(revision + 1, update.revision)
        broadcast()
    }

    private func publish() {
        revision &+= 1
        broadcast()
    }

    private func broadcast() {
        let current = snapshot
        for continuation in subscribers.values { continuation.yield(current) }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private static func entitlement(from transaction: Transaction) -> BillingEntitlement {
        BillingEntitlement(
            productID: transaction.productID,
            transactionID: String(transaction.id),
            purchasedAt: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate
        )
    }

    private static func value(from result: VerificationResult<Transaction>, transaction: Transaction) -> BillingTransaction {
        BillingTransaction(
            productID: transaction.productID,
            transactionID: String(transaction.id),
            originalTransactionID: String(transaction.originalID),
            purchaseDate: transaction.purchaseDate,
            signedDate: transaction.signedDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            jwsRepresentation: result.jwsRepresentation
        )
    }

    private static func transactionKey(base: IntentKey, transactionID: String) -> IntentKey {
        let raw = "(base.rawValue).(transactionID)"
        return IntentKey(rawValue: String(raw.prefix(128)))
    }
}

#else

/// StoreKit is unavailable on non-Apple package hosts.  Keeping the same
/// actor/API lets pure platform tests and Linux tooling compile without a
/// StoreKit SDK; an iOS build always selects the implementation above.
public actor StoreKitBillingStore: BillingStore {
    private let fallback: (any BillingStore)?

    public init(
        configuration: StoreKitBillingConfiguration,
        transactionSink: (any BillingTransactionSubmitting)? = nil,
        fallback: (any BillingStore)? = nil
    ) {
        self.fallback = fallback
    }

    public func updates() async -> AsyncStream<SourceSnapshot<BillingState>> {
        if let fallback { return await fallback.updates() }
        let (stream, continuation) = AsyncStream.makeStream(of: SourceSnapshot<BillingState>.self)
        continuation.yield(SourceSnapshot(revision: 1, value: BillingState(plans: [], currentPlanID: nil), connection: .offline(reason: StoreKitBillingError.unavailable.userMessage)))
        continuation.finish()
        return stream
    }

    public func purchase(_ planID: String, key: IntentKey) async throws -> IntentReceipt {
        if let fallback { return try await fallback.purchase(planID, key: key) }
        return .refused(key: key, reason: StoreKitBillingError.unavailable.userMessage)
    }

    public func restore(key: IntentKey) async throws -> IntentReceipt {
        if let fallback { return try await fallback.restore(key: key) }
        return .refused(key: key, reason: StoreKitBillingError.unavailable.userMessage)
    }
}

#endif
