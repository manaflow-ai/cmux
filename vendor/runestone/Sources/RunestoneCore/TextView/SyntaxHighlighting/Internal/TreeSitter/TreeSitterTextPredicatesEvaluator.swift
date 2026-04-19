import Foundation

final class TreeSitterTextPredicatesEvaluator {
    private let match: TreeSitterQueryMatch
    private let stringView: StringView
#if DEBUG
    static var previousUnsupportedPredicateNames: [String] = []
#endif

    init(match: TreeSitterQueryMatch, stringView: StringView) {
        self.match = match
        self.stringView = stringView
    }

    func evaluatePredicates(in capture: TreeSitterCapture) -> Bool {
        guard !capture.textPredicates.isEmpty else {
            return true
        }
        for textPredicate in capture.textPredicates {
            switch textPredicate {
            case .captureEqualsString(let parameters):
                if !evaluate(using: parameters) {
                    return false
                }
            case .captureEqualsCapture(let parameters):
                if !evaluate(using: parameters) {
                    return false
                }
            case .captureMatchesPattern(let parameters):
                if !evaluate(using: parameters) {
                    return false
                }
            case .unsupported(let parameters):
                #if DEBUG
                if !Self.previousUnsupportedPredicateNames.contains(parameters.name) {
                    Self.previousUnsupportedPredicateNames.append(parameters.name)
                    print("Unsupported predicate '\(parameters.name)'."
                          + " This message is only printed once and only when running in the debug configuration.")
                }
                #endif
                return false
            }
        }
        return true
    }
}

private extension TreeSitterTextPredicatesEvaluator {
    func evaluate(using parameters: TreeSitterTextPredicate.CaptureEqualsStringParameters) -> Bool {
        guard let capture = match.capture(forIndex: parameters.captureIndex) else {
            return false
        }
        let byteRange = capture.byteRange
        let range = NSRange(byteRange)
        let contentText = stringView.substring(in: range)
        let comparisonResult = contentText == parameters.string
        return comparisonResult == parameters.isPositive
    }

    func evaluate(using parameters: TreeSitterTextPredicate.CaptureEqualsCaptureParameters) -> Bool {
        guard let lhsCapture = match.capture(forIndex: parameters.lhsCaptureIndex) else {
            return false
        }
        guard let rhsCapture = match.capture(forIndex: parameters.lhsCaptureIndex) else {
            return false
        }
        let lhsByteRange = lhsCapture.byteRange
        let rhsByteRange = rhsCapture.byteRange
        let lhsRange = NSRange(lhsByteRange)
        let rhsRange = NSRange(rhsByteRange)
        let lhsContentText = stringView.substring(in: lhsRange)
        let rhsContentText = stringView.substring(in: rhsRange)
        let comparisonResult = lhsContentText == rhsContentText
        return comparisonResult == parameters.isPositive
    }

    func evaluate(using parameters: TreeSitterTextPredicate.CaptureMatchesPatternParameters) -> Bool {
        guard let capture = match.capture(forIndex: parameters.captureIndex) else {
            return false
        }
        let byteRange = capture.byteRange
        let range = NSRange(location: byteRange.location.value / 2, length: byteRange.length.value / 2)
        guard let contentText = stringView.substring(in: range) else {
            return false
        }
        let matchingRange = contentText.range(of: parameters.pattern, options: .regularExpression)
        let isMatch = matchingRange != nil
        return isMatch == parameters.isPositive
    }
}
