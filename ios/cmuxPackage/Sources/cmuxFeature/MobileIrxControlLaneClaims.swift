import Foundation

struct MobileIrxControlLaneClaims {
    private var ownerBySession: [String: UUID] = [:]

    mutating func claim(sessionID: String, ownerID: UUID) -> Bool {
        if let existingOwner = ownerBySession[sessionID], existingOwner != ownerID {
            return false
        }
        ownerBySession[sessionID] = ownerID
        return true
    }

    mutating func release(ownerID: UUID) {
        ownerBySession = ownerBySession.filter { $0.value != ownerID }
    }

    mutating func removeAll() {
        ownerBySession.removeAll()
    }
}

