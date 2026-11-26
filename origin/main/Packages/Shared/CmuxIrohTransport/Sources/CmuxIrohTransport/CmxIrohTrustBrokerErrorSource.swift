import Foundation

enum CmxIrohTrustBrokerErrorSource: String, Decodable {
    case ingressIP = "ingress_ip"
    case accountBudget = "account_budget"
    case deviceBudget = "device_budget"
    case authProvider = "auth_provider"
}
