import Foundation

/// `CloudMachine` as the Worker sends it (snake_case, cmux.wire/1).
struct WireCloudMachine: Decodable {
    struct Size: Decodable {
        var cpu: Int?
        var memory_mb: Int?
        var disk_mb: Int?
    }

    struct Image: Decodable {
        var id: String?
        var daemon_version: String?
    }

    struct IdlePolicy: Decodable {
        var idle_seconds: Int?
    }

    struct Failure: Decodable {
        var code: String
        var message: String
        var at: Double
    }

    var id: String
    var creator: String?
    var name: String?
    var size: Size?
    var status: String
    var image: Image?
    var host: String?
    var classic: Bool?
    var created_at: Double?
    var last_active_at: Double?
    var idle_policy: IdlePolicy?
    var error: Failure?
    var pause_reason: String?
    var revision: String?
}
