public import CmuxiOSFeatureKit
public import CmuxMobileWire

extension CloudIntent {
    /// The op's params (cloud-client-contract.md 1.3).
    public var params: [String: JSONValue] {
        switch self {
        case .create(let name, let size):
            var sizeParams: [String: JSONValue] = [:]
            if let cpu = size.cpu { sizeParams["cpu"] = .int(Int64(cpu)) }
            if let memory = size.memoryMB { sizeParams["memory_mb"] = .int(Int64(memory)) }
            if let disk = size.diskMB { sizeParams["disk_mb"] = .int(Int64(disk)) }
            var params: [String: JSONValue] = ["size": .object(sizeParams)]
            if let name = name.flatMap(CloudCreateOptions.normalizedName) { params["name"] = .string(name) }
            return params
        case .start(let id), .pause(let id), .delete(let id):
            return ["machine": .string(id)]
        case .rename(let id, let name):
            return ["machine": .string(id), "name": .string(name)]
        }
    }
}
