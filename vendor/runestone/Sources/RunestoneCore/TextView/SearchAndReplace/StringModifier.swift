import Foundation

enum StringModifier {
    case uppercaseLetter
    case uppercaseAllLetters
    case lowercaseLetter
    case lowercaseAllLetters

    var character: Character {
        switch self {
        case .uppercaseLetter:
            return "u"
        case .uppercaseAllLetters:
            return "U"
        case .lowercaseLetter:
            return "l"
        case .lowercaseAllLetters:
            return "L"
        }
    }
    var string: String {
        "\\" + String(character)
    }

    private var terminatesStringModification: Bool {
        switch self {
        case .uppercaseAllLetters, .lowercaseAllLetters:
            return true
        case .uppercaseLetter, .lowercaseLetter:
            return false
        }
    }

    static func string(byApplying modifiers: [Self], to string: String) -> String {
        guard !modifiers.isEmpty else {
            return string
        }
        var stringIndex = string.startIndex
        var modifierIndex = modifiers.startIndex
        var result = ""
        while stringIndex < string.endIndex && modifierIndex < modifiers.endIndex {
            let modifier = modifiers[modifierIndex]
            switch modifier {
            case .uppercaseLetter:
                result += string[stringIndex].uppercased()
            case .lowercaseLetter:
                result += string[stringIndex].lowercased()
            case .uppercaseAllLetters:
                result += string[stringIndex ..< string.endIndex].uppercased()
            case .lowercaseAllLetters:
                result += string[stringIndex ..< string.endIndex].lowercased()
            }
            if modifier.terminatesStringModification {
                stringIndex = string.endIndex
            } else {
                stringIndex = string.index(after: stringIndex)
            }
            modifierIndex = modifiers.index(after: modifierIndex)
        }
        if stringIndex < string.endIndex {
            result += string[stringIndex ..< string.endIndex]
        }
        return result
    }
}
