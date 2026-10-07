import Foundation

/// A string prepared for matching once, when its owner's snapshot changes,
/// so a keystroke never normalizes candidate text again.
///
/// Normalization folds case, diacritics, width and hiragana to katakana per
/// character. A character may fold to several units ("ß" to "ss"); `origins`
/// maps every unit back to its character offset in `original`, so match
/// ranges highlight the right characters.
public struct SearchText: Hashable, Sendable {
    public let original: String
    let units: [Character]
    /// The character offset in `original` of each unit.
    let origins: [Int]
    /// Whether each unit begins a word.
    let wordStarts: [Bool]

    /// - Parameter limit: characters of `text` to index; long bodies are cut
    ///   so 4 KiB of Markdown costs a bounded amount per keystroke.
    public init(_ text: String, limit: Int = .max) {
        original = text
        var units: [Character] = []
        var origins: [Int] = []
        var wordStarts: [Bool] = []
        units.reserveCapacity(min(text.count, limit))
        var previous: Character?
        for (offset, character) in text.enumerated() {
            if offset >= limit { break }
            let startsWord = Self.startsWord(character, after: previous)
            var first = true
            for unit in Self.fold(character) {
                units.append(unit)
                origins.append(offset)
                wordStarts.append(startsWord && first)
                first = false
            }
            previous = character
        }
        self.units = units
        self.origins = origins
        self.wordStarts = wordStarts
    }

    public var isEmpty: Bool { units.isEmpty }

    /// Character offsets in `original` covered by the unit range.
    func characterRange(units range: Range<Int>) -> Range<Int> {
        guard !range.isEmpty else { return 0..<0 }
        return origins[range.lowerBound]..<(origins[range.upperBound - 1] + 1)
    }

    // MARK: Normalization

    /// Folded units of one character. ASCII takes a fast path because most
    /// titles, paths and agent output are ASCII.
    static func fold(_ character: Character) -> [Character] {
        if character.isASCII, let ascii = character.asciiValue {
            if ascii >= 65, ascii <= 90 { return [Character(Unicode.Scalar(ascii + 32))] }
            return [character]
        }
        let folded = String(character).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result: [Character] = []
        for unit in folded { result.append(katakana(unit)) }
        return result.isEmpty ? [character] : result
    }

    /// Hiragana (U+3041 to U+3096) maps to its katakana (+0x60), so either
    /// script finds the other.
    static func katakana(_ character: Character) -> Character {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
              (0x3041...0x3096).contains(scalar.value),
              let shifted = Unicode.Scalar(scalar.value + 0x60) else { return character }
        return Character(shifted)
    }

    /// A word starts at the beginning, after a separator, at a lower-to-upper
    /// case change (`newTask`) and at a letter/digit change (`tab2`).
    static func startsWord(_ character: Character, after previous: Character?) -> Bool {
        guard let previous else { return true }
        let isWordCharacter = character.isLetter || character.isNumber
        guard isWordCharacter else { return false }
        if !(previous.isLetter || previous.isNumber) { return true }
        if previous.isLowercase, character.isUppercase { return true }
        if previous.isLetter != character.isLetter { return true }
        return false
    }
}
