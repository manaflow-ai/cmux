import CmuxiOSFeatureKit
import Foundation

/// Several directories as one: yields once every directory has answered,
/// then on each change, in directory order, the first descriptor of a host
/// id winning. Lane C12 merges B6's Macs with the team's Cloud machines.
public struct CompositeHostDirectory: WorkspaceHostDirectory {
    public let directories: [any WorkspaceHostDirectory]

    public init(_ directories: [any WorkspaceHostDirectory]) { self.directories = directories }

    public func hosts() async -> AsyncStream<[WorkspaceHostDescriptor]> {
        let (output, continuation) = AsyncStream.makeStream(
            of: [WorkspaceHostDescriptor].self, bufferingPolicy: .bufferingNewest(1))
        let (merged, mergedContinuation) = AsyncStream.makeStream(of: (Int, [WorkspaceHostDescriptor]).self)
        let children = directories.enumerated().map { index, directory in
            Task {
                for await hosts in await directory.hosts() { mergedContinuation.yield((index, hosts)) }
            }
        }
        let count = directories.count
        let combiner = Task {
            var latest: [Int: [WorkspaceHostDescriptor]] = [:]
            var last: [WorkspaceHostDescriptor]?
            for await (index, hosts) in merged {
                latest[index] = hosts
                guard latest.count == count else { continue }
                var seen = Set<HostID>()
                let combined = (0..<count).flatMap { latest[$0] ?? [] }.filter { seen.insert($0.id).inserted }
                if combined != last {
                    last = combined
                    continuation.yield(combined)
                }
            }
        }
        continuation.onTermination = { _ in
            for child in children { child.cancel() }
            combiner.cancel()
            mergedContinuation.finish()
        }
        return output
    }
}
