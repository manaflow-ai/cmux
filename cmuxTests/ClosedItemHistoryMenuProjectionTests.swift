import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct ClosedItemHistoryMenuProjectionTests {
    @Test
    func boundedProjectionStopsAfterReachingVisibleItemLimit() {
        var visitedRecordCount = 0
        let newestFirstRecords = CountingHistorySequence(
            elements: [6, 5, 4, 3, 2, 1],
            onElement: { visitedRecordCount += 1 }
        )

        let projection = ClosedItemHistoryMenuProjector.project(
            newestFirst: newestFirstRecords,
            eligibleItemCount: 3,
            maxItemCount: 2,
            isEligible: { !$0.isMultiple(of: 2) },
            transform: { $0 }
        )

        #expect(projection.items == [5, 3])
        #expect(projection.isLimited)
        #expect(
            visitedRecordCount == 4,
            "Bounded projection must stop once it finds the requested visible items."
        )
    }
}

private struct CountingHistorySequence<Element>: Sequence {
    let elements: [Element]
    let onElement: () -> Void

    func makeIterator() -> Iterator {
        Iterator(elements: elements, onElement: onElement)
    }

    struct Iterator: IteratorProtocol {
        let elements: [Element]
        let onElement: () -> Void
        private var index = 0

        init(elements: [Element], onElement: @escaping () -> Void) {
            self.elements = elements
            self.onElement = onElement
        }

        mutating func next() -> Element? {
            guard elements.indices.contains(index) else { return nil }
            onElement()
            defer { index += 1 }
            return elements[index]
        }
    }
}
