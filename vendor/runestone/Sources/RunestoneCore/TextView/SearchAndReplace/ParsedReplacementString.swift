import Foundation

struct ParsedReplacementString: Equatable {
    enum Component: Equatable {
        struct TextParameters: Equatable {
            let text: String
        }

        struct PlaceholderParameters: Equatable {
            let modifiers: [StringModifier]
            let index: Int
        }

        case text(TextParameters)
        case placeholder(PlaceholderParameters)

        static func text(_ text: String) -> Self {
            let parameters = TextParameters(text: text)
            return .text(parameters)
        }

        static func placeholder(_ index: Int) -> Self {
            let parameters = PlaceholderParameters(modifiers: [], index: index)
            return .placeholder(parameters)
        }

        static func placeholder(modifiers: [StringModifier], index: Int) -> Self {
            let parameters = PlaceholderParameters(modifiers: modifiers, index: index)
            return .placeholder(parameters)
        }
    }

    let components: [Component]

    var containsPlaceholder: Bool {
        components.contains { component in
            switch component {
            case .text:
                return false
            case .placeholder:
                return true
            }
        }
    }

    func string(byMatching textCheckingResult: NSTextCheckingResult, in string: NSString) -> String {
        var result = ""
        for component in components {
            switch component {
            case .text(let parameters):
                result += parameters.text
            case .placeholder(let parameters):
                if parameters.index < textCheckingResult.numberOfRanges {
                    let range = textCheckingResult.range(at: parameters.index)
                    let substring = string.substring(with: range)
                    if parameters.index == 0 {
                        // Visual Studio Code doesn't apply modifiers to capture groups with index 0 (i.e. the entire match).
                        // We copy Visual Studio Code's behavior as it's likely familiar to our users.
                        result += substring
                    } else {
                        result += StringModifier.string(byApplying: parameters.modifiers, to: substring)
                    }
                } else {
                    // Placeholder is out of bounds so we just insert the raw placeholder.
                    result += "$\(parameters.index)"
                }
            }
        }
        return result
    }
}

extension ParsedReplacementString: CustomDebugStringConvertible {
    var debugDescription: String {
        var stringComponents: [String] = []
        for component in components {
            switch component {
            case .text(let textParameters):
                stringComponents.append(".text(\"\(textParameters.text)\")")
            case .placeholder(let placeholderParameters):
                var string = ".placeholder("
                if !placeholderParameters.modifiers.isEmpty {
                    string += String(placeholderParameters.modifiers.map(\.character))
                }
                string += "\"\(placeholderParameters.index)\")"
                stringComponents.append(string)
            }
        }
        return stringComponents.joined(separator: ", ")
    }
}
