import Foundation
import CMUXAuthCore
import StackAuth

typealias StackAuthUser = CMUXAuthUser

extension CMUXAuthUser {
    init(currentUser: CurrentUser) async {
        let userId = await currentUser.id
        let email = await currentUser.primaryEmail
        let name = await currentUser.displayName
        self.init(id: userId, primaryEmail: email, displayName: name)
    }
}
