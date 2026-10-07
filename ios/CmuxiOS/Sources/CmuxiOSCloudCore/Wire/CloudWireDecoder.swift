public import CmuxiOSFeatureKit
public import CmuxMobileWire
import Foundation

/// Maps `cmux.wire/1` Cloud values onto FeatureKit types. Unknown statuses
/// and pause reasons fail the record (a protocol break), never guess.
public struct CloudWireDecoder: Sendable {
    public init() {}

    public func machine(_ value: JSONValue) throws -> CloudMachine {
        let wire = try value.decode(as: WireCloudMachine.self)
        guard let status = CloudMachineStatus(rawValue: wire.status) else { throw CloudWireDecodeError.unknownStatus(wire.status) }
        var pauseReason: CloudPauseReason?
        if let raw = wire.pause_reason {
            guard let reason = CloudPauseReason(rawValue: raw) else { throw CloudWireDecodeError.unknownStatus(raw) }
            pauseReason = reason
        }
        return CloudMachine(
            id: wire.id, creator: wire.creator ?? "", name: wire.name,
            size: CloudMachineSize(cpu: wire.size?.cpu, memoryMB: wire.size?.memory_mb, diskMB: wire.size?.disk_mb),
            status: status, daemonVersion: wire.image?.daemon_version, host: wire.host.map(HostID.init(rawValue:)),
            isClassic: wire.classic ?? false, createdAt: Self.date(wire.created_at) ?? Date(timeIntervalSince1970: 0),
            lastActiveAt: Self.date(wire.last_active_at), idleSeconds: wire.idle_policy?.idle_seconds ?? 0,
            failure: wire.error.map { CloudMachineFailure(code: $0.code, message: $0.message, at: Self.date($0.at) ?? Date(timeIntervalSince1970: 0)) },
            pauseReason: pauseReason, revision: Self.revision(wire.revision)
        )
    }

    public func page(_ value: JSONValue) throws -> CloudMachinePage {
        guard case .array(let rows)? = value["machines"] else { throw CloudWireDecodeError.missing("machines") }
        return CloudMachinePage(machines: try rows.map(machine), nextCursor: value["next_cursor"]?.stringValue,
                                revision: Self.revision(value["revision"]?.stringValue))
    }

    public func plan(_ value: JSONValue) throws -> CloudPlan {
        let wire = try value.decode(as: WireCloudPlan.self)
        return CloudPlan(
            planID: wire.plan_id, upgradePlan: wire.upgrade_plan,
            limits: CloudPlanLimits(maxActive: wire.limits?.max_active ?? 0, maxSaved: wire.limits?.max_saved ?? 0,
                                    memoryOptionsMB: wire.limits?.memory_options_mb ?? [],
                                    lockedMemoryOptionsMB: wire.limits?.locked_memory_options_mb ?? [],
                                    vmHoursIncluded: wire.limits?.vm_hours_included),
            usage: CloudPlanUsage(active: wire.usage?.active ?? 0, saved: wire.usage?.saved ?? 0,
                                  vmHoursUsed: wire.usage?.vm_hours_used ?? 0,
                                  periodEnd: Self.date(wire.usage?.period_end) ?? Date(timeIntervalSince1970: 0))
        )
    }

    /// `cmux.wire/1` revisions are decimal strings; anything else is 0.
    public static func revision(_ raw: String?) -> UInt64 { raw.flatMap(UInt64.init) ?? 0 }

    private static func date(_ millis: Double?) -> Date? { millis.map { Date(timeIntervalSince1970: $0 / 1000) } }
}
