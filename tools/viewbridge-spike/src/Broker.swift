// VB spike broker. Throwaway demo binary (localization-exempt per spike rules).
//
// Rendezvous process. Both the ViewBridge service child and the host connect to
// this by a hardcoded launchd mach service name. The service child hands its
// anonymous NSXPCListenerEndpoint here (transferred as an XPC method argument so
// NSXPCCoder can marshal the live mach send right); the host fetches it.
//
// We need a real mach channel because NSXPCListenerEndpoint refuses NSKeyedArchiver
// ("This class may only be encoded by an NSXPCCoder"), so a flat file/pipe cannot
// carry the endpoint. A launchd-registered name is the simplest channel both
// unrelated processes can reach.

import Foundation

let kBrokerMachName = "com.cmux.vbridge.broker"

@objc protocol VBBrokerProtocol {
    func setServiceEndpoint(_ endpoint: NSXPCListenerEndpoint)
    func getServiceEndpoint(reply: @escaping (NSXPCListenerEndpoint?) -> Void)
}

final class Broker: NSObject, VBBrokerProtocol, NSXPCListenerDelegate {
    private let lock = NSLock()
    private var stored: NSXPCListenerEndpoint?

    func setServiceEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        lock.lock(); stored = endpoint; lock.unlock()
        FileHandle.standardError.write("BROKER: stored service endpoint\n".data(using: .utf8)!)
    }

    func getServiceEndpoint(reply: @escaping (NSXPCListenerEndpoint?) -> Void) {
        lock.lock(); let e = stored; lock.unlock()
        FileHandle.standardError.write("BROKER: getServiceEndpoint -> \(e != nil ? "present" : "nil")\n".data(using: .utf8)!)
        reply(e)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: VBBrokerProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }
}

let broker = Broker()
// machServiceName listener: launchd routes the registered name to us.
let listener = NSXPCListener(machServiceName: kBrokerMachName)
listener.delegate = broker
listener.resume()
FileHandle.standardError.write("BROKER: listening on \(kBrokerMachName)\n".data(using: .utf8)!)
RunLoop.current.run()
