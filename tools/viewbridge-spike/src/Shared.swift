// Shared declarations for the VB spike host + service. Throwaway demo code.
import Foundation

let kBrokerMachName = "com.cmux.vbridge.broker"

@objc protocol VBBrokerProtocol {
    func setServiceEndpoint(_ endpoint: NSXPCListenerEndpoint)
    func getServiceEndpoint(reply: @escaping (NSXPCListenerEndpoint?) -> Void)
}

enum SpikeLog {
    static func err(_ tag: String, _ msg: String) {
        FileHandle.standardError.write("\(tag): \(msg)\n".data(using: .utf8)!)
    }
}
