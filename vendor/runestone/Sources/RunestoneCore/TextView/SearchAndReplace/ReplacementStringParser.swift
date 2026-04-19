import Foundation

final class ReplacementStringParser {
    private enum State {
        case `default`
        case placeholder
        case escapeSequence
    }

    private let string: String
    private var state: State = .default
    private var collectedString = ""
    private var collectedModifiers: [StringModifier] = []
    private var components: [ParsedReplacementString.Component] = []
    private let numberCharacterSet = CharacterSet(charactersIn: "1234567890")

    init(string: String) {
        self.string = string
    }

    func parse() -> ParsedReplacementString {
        var index = string.startIndex
        while index < string.endIndex {
            let character = string[index]
            take(character, at: index)
            index = string.index(after: index)
        }
        if let component = makeComponent() {
            components.append(component)
        }
        return ParsedReplacementString(components: components)
    }
}

private extension ReplacementStringParser {
    private func take(_ character: Character, at index: String.Index) {
        if state == .placeholder {
            takeCharacterInPlaceholder(character, at: index)
        } else if state == .escapeSequence {
            takeCharacterInEscapeSequence(character)
        } else if character == "\\" {
            collectedString += String(character)
            state = .escapeSequence
        } else if character == "$" {
            takeDollarSign(at: index)
        } else {
            appendCollectedModifiersToCollectedString()
            collectedString += String(character)
            state = .default
        }
    }

    private func takeCharacterInPlaceholder(_ character: Character, at index: String.Index) {
        if isCharacterValidInPlaceholderIndex(character) {
            collectedString += String(character)
        } else if let component = makeComponent() {
            components.append(component)
            state = .default
            take(character, at: index)
        } else {
            // swiftlint:disable:next line_length
            fatalError("We thought we were collecting a placeholder but the current character isn't valid in a placeholder and the collected string isn't a valid placeholder value either. Since we're peeking at the next character when starting a placeholder we should never be able to end up in this case.")
        }
    }

    private func takeCharacterInEscapeSequence(_ character: Character) {
        switch character {
        case "\\":
            collectedString.removeLast()
            collectedString += String(character)
            state = .default
        case "n":
            collectedString.removeLast()
            collectedString += "\n"
            state = .default
        case "r":
            collectedString.removeLast()
            collectedString += "\r"
            state = .default
        case "t":
            collectedString.removeLast()
            collectedString += "\t"
            state = .default
        case "u":
            collectedString.removeLast()
            collectedModifiers.append(.uppercaseLetter)
            state = .default
        case "U":
            collectedString.removeLast()
            collectedModifiers.append(.uppercaseAllLetters)
            state = .default
        case "l":
            collectedString.removeLast()
            collectedModifiers.append(.lowercaseLetter)
            state = .default
        case "L":
            collectedString.removeLast()
            collectedModifiers.append(.lowercaseAllLetters)
            state = .default
        case "$":
            collectedString.removeLast()
            appendCollectedModifiersToCollectedString()
            collectedString += String(character)
            state = .default
        default:
            // We remove the backslash and insert it later to ensure our collected modifiers are inserted infront of the character.
            collectedString.removeLast()
            appendCollectedModifiersToCollectedString()
            collectedString += "\\"
            collectedString += String(character)
            state = .default
        }
    }

    private func takeDollarSign(at index: String.Index) {
        if canStartPlaceholder(at: index) {
            if let component = makeComponent() {
                components.append(component)
            }
            state = .placeholder
        } else {
            appendCollectedModifiersToCollectedString()
            collectedString += "$"
            state = .default
        }
    }

    private func canStartPlaceholder(at index: String.Index) -> Bool {
        guard index < string.index(before: string.endIndex) else {
            return false
        }
        let peekCharacterIndex = string.index(after: index)
        let peekCharacter = string[peekCharacterIndex]
        return isCharacterValidInPlaceholderIndex(peekCharacter)
    }

    private func isCharacterValidInPlaceholderIndex(_ character: Character) -> Bool {
        let unicodeScalars = character.unicodeScalars
        return unicodeScalars.count == 1 && numberCharacterSet.contains(unicodeScalars[unicodeScalars.startIndex])
    }

    private func appendCollectedModifiersToCollectedString() {
        if !collectedModifiers.isEmpty {
            collectedString += collectedModifiers.map(\.string).joined()
            collectedModifiers = []
        }
    }

    private func makeComponent() -> ParsedReplacementString.Component? {
        switch state {
        case .default, .escapeSequence:
            let component = makeTextComponent()
            collectedString = ""
            return component
        case .placeholder:
            let component = makePlaceholderComponent()
            collectedString = ""
            collectedModifiers = []
            return component
        }
    }

    private func makeTextComponent() -> ParsedReplacementString.Component? {
        if !collectedString.isEmpty {
            let parameters = ParsedReplacementString.Component.TextParameters(text: collectedString)
            return .text(parameters)
        } else {
            return nil
        }
    }

    private func makePlaceholderComponent() -> ParsedReplacementString.Component? {
        if !collectedString.isEmpty, let index = Int(collectedString) {
            let parameters = ParsedReplacementString.Component.PlaceholderParameters(modifiers: collectedModifiers, index: index)
            return .placeholder(parameters)
        } else {
            return nil
        }
    }
}
