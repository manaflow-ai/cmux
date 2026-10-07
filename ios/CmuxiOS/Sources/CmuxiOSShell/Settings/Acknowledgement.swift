/// One open source project the app ships.
struct Acknowledgement: Identifiable, Hashable {
    let name: String
    let license: String
    let url: String

    var id: String { name }
}
