import Foundation

/// Refuses every redirect, so a bearer never follows to another origin.
final class CloudRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Completion-handler form: Xcode 26.6's compiler crashes emitting the
        // ObjC thunk for the async variant.
        completionHandler(nil)
    }
}
