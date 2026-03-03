import Foundation
import StackAuth

struct StackAuthUser: Codable, Equatable {
    let id: String
    let primaryEmail: String?
    let displayName: String?

    init(id: String, primaryEmail: String?, displayName: String?) {
        self.id = id
        self.primaryEmail = primaryEmail
        self.displayName = displayName
    }

    init(currentUser: CurrentUser) async {
        let userId = await currentUser.id
        let email = await currentUser.primaryEmail
        let name = await currentUser.displayName
        self.init(id: userId, primaryEmail: email, displayName: name)
    }
}
