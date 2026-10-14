#if os(iOS)
// THROWAWAY (never merged): App Review screenshot harness. Renders the real
// MobilePlansView over a real BillingModel. The StoreKit seam reads products
// from a copy of ios/Config/cmux-dev.storekit with the App Store product ids
// (StoreKitTest cannot run outside XCTest on the fleet simulator), and the
// account-token response is a fixed eligible free account.
import CMUXMobileCore
import CmuxMobileBilling
import CmuxMobileBillingUI
import Foundation
import SwiftUI

public struct ReviewScreenshotRoot: View {
    @State private var model: BillingModel
    private let period: BillingPeriod

    public init() {
        let monthly = (Bundle.main.bundleIdentifier ?? "").contains("shotm")
        period = monthly ? .monthly : .yearly
        _model = State(initialValue: BillingModel(
            api: ReviewFixtureBillingAPI(),
            store: ReviewConfigStoreKitClient(),
            analytics: nil
        ))
    }

    public var body: some View {
        NavigationStack {
            MobilePlansView(entryPoint: .settings, initialPeriod: period)
        }
        .environment(model)
    }
}

struct ReviewFixtureBillingAPI: BillingAPI {
    func accountToken() async throws -> BillingAccount {
        BillingAccount(
            appAccountToken: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            eligible: true,
            reason: nil,
            currentPlan: BillingCurrentPlan(planID: .free, source: .none),
            products: [
                BillingProductReference(productID: "com.cmux.app.go.monthly", planID: .go),
                BillingProductReference(productID: "com.cmux.app.pro.monthly", planID: .pro),
                BillingProductReference(productID: "com.cmux.app.pro.yearly", planID: .pro),
                BillingProductReference(productID: "com.cmux.app.max.monthly", planID: .max),
                BillingProductReference(productID: "com.cmux.app.max.yearly", planID: .max),
            ]
        )
    }

    func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt {
        throw URLError(.notConnectedToInternet)
    }
}

/// Products from the StoreKit configuration file, priced in USD as the
/// configuration's USA storefront would show them.
struct ReviewConfigStoreKitClient: StoreKitClient {
    func products(for ids: [String]) async throws -> [StoreProduct] {
        let data = Data(storeKitConfig.utf8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["subscriptionGroups"] as? [[String: Any]] else { return [] }
        let style = Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US"))
        var result: [StoreProduct] = []
        for group in groups {
            for sub in group["subscriptions"] as? [[String: Any]] ?? [] {
                guard let id = sub["productID"] as? String, ids.contains(id),
                      let priceText = sub["displayPrice"] as? String,
                      let price = Decimal(string: priceText) else { continue }
                let yearly = (sub["recurringSubscriptionPeriod"] as? String) == "P1Y"
                let localization = (sub["localizations"] as? [[String: Any]])?.first
                result.append(StoreProduct(
                    id: id,
                    displayName: localization?["displayName"] as? String ?? id,
                    productDescription: localization?["description"] as? String ?? "",
                    displayPrice: price.formatted(style),
                    periodUnitName: yearly ? "year" : "month",
                    price: price,
                    currencyCode: "USD",
                    monthlyEquivalentDisplayPrice: yearly ? (price / 12).formatted(style) : nil
                ))
            }
        }
        return result
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> StorePurchaseResult { .userCancelled }
    func transactionUpdates() -> AsyncStream<StoreTransactionVerification> { AsyncStream { _ in } }
    func unfinishedTransactions() async -> [StoreTransactionVerification] { [] }
    func currentEntitlements() async -> [StoreTransactionVerification] { [] }
    func syncWithAppStore() async throws {}
    func storefrontCountryCode() async -> String? { "USA" }
    func finish(transactionID: UInt64) async {}
}

let storeKitConfig = #"""
{
  "appPolicies" : {
    "eula" : "",
    "policies" : [
      {
        "locale" : "en_US",
        "policyText" : "",
        "policyURL" : ""
      }
    ]
  },
  "identifier" : "5C3D7A21",
  "nonRenewingSubscriptions" : [],
  "products" : [],
  "settings" : {
    "_failTransactionsEnabled" : false,
    "_locale" : "en_US",
    "_storefront" : "USA",
    "_storeKitErrors" : []
  },
  "subscriptionGroups" : [
    {
      "id" : "21490001",
      "localizations" : [],
      "name" : "cmux",
      "subscriptions" : [
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "299.99",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "6749000001",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "Up to 5 Cloud VMs sharing 80 vCPUs and 160 GB RAM.",
              "displayName" : "cmux Max",
              "locale" : "en_US"
            }
          ],
          "productID" : "com.cmux.app.max.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Max Monthly",
          "subscriptionGroupID" : "21490001",
          "type" : "RecurringSubscription",
          "winbackOffers" : []
        },
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "74.99",
          "familyShareable" : false,
          "groupNumber" : 2,
          "internalID" : "6749000002",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM.",
              "displayName" : "cmux Pro",
              "locale" : "en_US"
            }
          ],
          "productID" : "com.cmux.app.pro.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Pro Monthly",
          "subscriptionGroupID" : "21490001",
          "type" : "RecurringSubscription",
          "winbackOffers" : []
        },
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "699.99",
          "familyShareable" : false,
          "groupNumber" : 2,
          "internalID" : "6749000004",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM.",
              "displayName" : "cmux Pro",
              "locale" : "en_US"
            }
          ],
          "productID" : "com.cmux.app.pro.yearly",
          "recurringSubscriptionPeriod" : "P1Y",
          "referenceName" : "Pro Yearly",
          "subscriptionGroupID" : "21490001",
          "type" : "RecurringSubscription",
          "winbackOffers" : []
        },
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "14.99",
          "familyShareable" : false,
          "groupNumber" : 3,
          "internalID" : "6749000003",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "1 Cloud VM with 2 vCPUs and 4 GB RAM, 40 VM-hours a month.",
              "displayName" : "cmux Go",
              "locale" : "en_US"
            }
          ],
          "productID" : "com.cmux.app.go.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Go Monthly",
          "subscriptionGroupID" : "21490001",
          "type" : "RecurringSubscription",
          "winbackOffers" : []
        }
      ]
    }
  ],
  "version" : {
    "major" : 4,
    "minor" : 0
  }
}
"""#
#endif
