import Foundation

enum TreeSitterPredicateMapper {
    struct MapResult {
        let properties: [String: String]
        let textPredicates: [TreeSitterTextPredicate]
    }

    static func map(_ predicates: [TreeSitterPredicate]) -> MapResult {
        var properties: [String: String] = [:]
        var textPredicates: [TreeSitterTextPredicate] = []
        for predicate in predicates {
            switch predicate.name {
            case "set!":
                let setProperties = self.properties(fromSetSteps: predicate.steps)
                properties[setProperties.name] = setProperties.value
            case "eq?":
                textPredicates.append(self.textPredicate(fromEqSteps: predicate.steps, isPositive: true))
            case "not-eq?":
                textPredicates.append(self.textPredicate(fromEqSteps: predicate.steps, isPositive: false))
            case "match?":
                textPredicates.append(self.textPredicate(fromMatchSteps: predicate.steps, isPositive: true))
            case "not-match?":
                textPredicates.append(textPredicate(fromMatchSteps: predicate.steps, isPositive: false))
            default:
                let parameters = TreeSitterTextPredicate.UnsupportedParameters(name: predicate.name)
                textPredicates.append(.unsupported(parameters))
            }
        }
        return MapResult(properties: properties, textPredicates: textPredicates)
    }
}

private extension TreeSitterPredicateMapper {
    private static func properties(fromSetSteps steps: [TreeSitterPredicate.Step]) -> (name: String, value: String) {
        guard steps.count == 2 else {
            fatalError("Set predicate must contain exactly two steps.")
        }
        switch (steps[0], steps[1]) {
        case let (.string(name), .string(value)):
            return (name, value)
        default:
            fatalError("Set predicate must contain exactly two string steps.")
        }
    }

    private static func textPredicate(fromEqSteps steps: [TreeSitterPredicate.Step], isPositive: Bool) -> TreeSitterTextPredicate {
        guard steps.count == 2 else {
            fatalError("eq? and not-eq? predicates must contain exactly two teps.")
        }
        switch (steps[0], steps[1]) {
        case let (.capture(captureIndex), .string(value)):
            return .captureEqualsString(.init(captureIndex: captureIndex, string: value, isPositive: isPositive))
        case let (.capture(lhsCaptureIndex), .capture(rhsCaptureIndex)):
            return .captureEqualsCapture(.init(lhsCaptureIndex: lhsCaptureIndex, rhsCaptureIndex: rhsCaptureIndex, isPositive: isPositive))
        default:
            fatalError("Predicate contains invalid combination of steps.")
        }
    }

    private static func textPredicate(fromMatchSteps steps: [TreeSitterPredicate.Step], isPositive: Bool) -> TreeSitterTextPredicate {
        guard steps.count == 2 else {
            fatalError("match? and not-match? predicates must contain exactly stwo teps.")
        }
        switch (steps[0], steps[1]) {
        case let (.capture(captureIndex), .string(value)):
            return .captureMatchesPattern(.init(captureIndex: captureIndex, pattern: value, isPositive: isPositive))
        default:
            fatalError("Predicate contains invalid combination of steps.")
        }
    }
}
