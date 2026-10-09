import Foundation

/// `CloudPlan` as the Worker sends it.
struct WireCloudPlan: Decodable {
    struct Limits: Decodable {
        var max_active: Int?
        var max_saved: Int?
        var memory_options_mb: [Int]?
        var locked_memory_options_mb: [Int]?
        var vm_hours_included: Double?
    }

    struct Usage: Decodable {
        var active: Int?
        var saved: Int?
        var vm_hours_used: Double?
        var period_end: Double?
    }

    var plan_id: String
    var upgrade_plan: String?
    var limits: Limits?
    var usage: Usage?
}
