// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

extension Array {

    /// Returns an array containing the results of mapping the given closure over the sequence’s
    /// elements concurrently.
    ///
    /// - Parameters:
    ///   - queue: The queue for performing concurrent computations.
    ///            If the given queue is serial, the values are mapped in a serial fashion.
    ///            Pass `nil` to perform computations on the current queue.
    ///   - transform: the block to perform concurrent computations over the given element.
    /// - Returns: an array of concurrently computed values.
    func concurrentMap<U>(queue: DispatchQueue?, _ transform: (Element) -> U) -> [U] {
        var result = [U?](repeating: nil, count: self.count)
        let resultQueue = DispatchQueue(label: "ConcurrentMapQueue")

        let execute = queue?.sync ?? { $0() }

        execute {
            DispatchQueue.concurrentPerform(iterations: self.count) { index in
                let value = transform(self[index])
                resultQueue.sync {
                    result[index] = value
                }
            }
        }

        return result.map { $0! }
    }
}
