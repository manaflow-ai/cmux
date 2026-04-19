import Foundation

enum Symbol {
    enum Character {
        static let lineFeed: Swift.Character = "\n"
        static let carriageReturn: Swift.Character = "\r"
        static let carriageReturnLineFeed: Swift.Character = "\r\n"
        static let lineSeparator: Swift.Character = "\u{2028}"
        static let tab: Swift.Character = "\t"
        static let space: Swift.Character = " "
        static let nonBreakingSpace: Swift.Character = "\u{A0}"
    }

    static let lineFeed = String(Self.Character.lineFeed)
    static let carriageReturn = String(Self.Character.carriageReturn)
    static let carriageReturnLineFeed = String(Self.Character.carriageReturnLineFeed)
    static let tab = String(Self.Character.tab)
    static let space = String(Self.Character.space)
}
