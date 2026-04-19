import TreeSitter

enum TreeSitterQueryError: Error {
    case syntax(offset: UInt32)
    case nodeType(offset: UInt32)
    case field(offset: UInt32)
    case capture(offset: UInt32)
    case structure(offset: UInt32)
    case unknown
}

final class TreeSitterQuery {
    let pointer: OpaquePointer

    private let language: UnsafePointer<TSLanguage>
    private var patternCount: UInt32 {
        ts_query_pattern_count(pointer)
    }

    init(source: String, language: UnsafePointer<TSLanguage>) throws {
        let errorOffset = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        let errorType = UnsafeMutablePointer<TSQueryError>.allocate(capacity: 1)
        let pointer = source.withCString { cstr in
            ts_query_new(language, cstr, UInt32(source.count), errorOffset, errorType)
        }
        defer {
            errorOffset.deallocate()
            errorType.deallocate()
        }
        switch errorType.pointee.rawValue {
        case 1:
            throw TreeSitterQueryError.syntax(offset: errorOffset.pointee)
        case 2:
            throw TreeSitterQueryError.nodeType(offset: errorOffset.pointee)
        case 3:
            throw TreeSitterQueryError.field(offset: errorOffset.pointee)
        case 4:
            throw TreeSitterQueryError.capture(offset: errorOffset.pointee)
        case 5:
            throw TreeSitterQueryError.structure(offset: errorOffset.pointee)
        default:
            if let pointer = pointer {
                self.language = language
                self.pointer = pointer
            } else {
                throw TreeSitterQueryError.unknown
            }
        }
    }

    deinit {
        ts_query_delete(pointer)
    }

    func captureName(forId id: UInt32) -> String {
        let lengthPointer = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        let cString = ts_query_capture_name_for_id(pointer, id, lengthPointer)
        lengthPointer.deallocate()
        return String(cString: cString!)
    }

    func predicates(forPatternIndex index: UInt32) -> [TreeSitterPredicate] {
        let lengthPointer = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        defer {
            lengthPointer.deallocate()
        }
        guard let rawSteps = ts_query_predicates_for_pattern(pointer, index, lengthPointer) else {
            return []
        }
        var predicates: [TreeSitterPredicate] = []
        var l = 0
        while l < lengthPointer.pointee {
            var steps: [TreeSitterPredicate.Step] = []
            let name = stringValue(forId: rawSteps.pointee.value_id)
            l += 1
            for i in 1 ..< .max {
                let step = (rawSteps + UnsafePointer<TSQueryPredicateStep>.Stride(i)).pointee
                l += 1
                if step.type == TSQueryPredicateStepTypeCapture {
                    steps.append(.capture(step.value_id))
                } else if step.type == TSQueryPredicateStepTypeString {
                    steps.append(.string(stringValue(forId: step.value_id)))
                } else if step.type == TSQueryPredicateStepTypeDone {
                    break
                }
            }
            let predicate = TreeSitterPredicate(name: name, steps: steps)
            predicates.append(predicate)
        }
        return predicates
    }
}

private extension TreeSitterQuery {
    private func stringValue(forId id: uint) -> String {
        let lengthPointer = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        defer {
            lengthPointer.deallocate()
        }
        let cString = ts_query_string_value_for_id(pointer, id, lengthPointer)
        return String(cString: cString!)
    }
}
