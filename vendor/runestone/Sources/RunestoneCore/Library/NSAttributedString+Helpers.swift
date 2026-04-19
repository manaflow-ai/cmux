import Foundation

extension NSAttributedString {
    func isWhitespaceCharacter(at location: Int) -> Bool {
        guard location < length else {
            return false
        }
        let range = NSRange(location: location, length: 1)
        let characterSet: CharacterSet = .whitespaces
        let attributingSubstring = attributedSubstring(from: range)
        return characterSet.containsAllCharacters(of: attributingSubstring.string)
    }
}
