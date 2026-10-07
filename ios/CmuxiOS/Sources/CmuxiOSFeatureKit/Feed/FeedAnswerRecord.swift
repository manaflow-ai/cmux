public import Foundation

/// The owner's record of the first accepted answer.
public struct FeedAnswerRecord: Hashable, Sendable {
    /// The answer, or nil when its shape is unknown to this build.
    public var reply: FeedReply?
    /// The answering device's name ("iPhone", "Mac Studio").
    public var device: String?
    public var at: Date

    public init(reply: FeedReply?, device: String? = nil, at: Date) {
        self.reply = reply
        self.device = device
        self.at = at
    }
}
