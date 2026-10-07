import CmuxiOSFeatureKit
import Foundation

/// One browser connection accepted by a `LoopbackProxy`: read the first
/// request head, check the route token, rewrite it, dial the tunnel, then
/// move bytes both ways until both directions ended.
struct ProxyConnection {
    let local: LoopbackConnectionStream
    let token: String
    let remotePort: UInt16
    let localPort: UInt16
    let dialer: any TunnelDialer

    func run() async {
        guard let (head, rest) = await readHead() else { return }
        guard let presented = head.cookie(WebTunnelCookie.name), WebTunnelCookie.matches(presented, token) else {
            await answer(.forbidden)
            return
        }
        let rewrite = localPort != remotePort
        let forwarded = head.forwarded(strippingCookie: WebTunnelCookie.name, host: rewrite ? "localhost:\(remotePort)" : nil,
                                       closeAfter: rewrite)
        let remote: any TunnelStream
        do {
            remote = try await dialer.dial(port: remotePort)
        } catch TunnelDialError.refused(let code, _) {
            await answer(.badGateway("localhost:\(remotePort) refused the connection (\(code))."))
            return
        } catch {
            await answer(.badGateway("No connection to the machine that serves localhost:\(remotePort)."))
            return
        }
        do {
            try await remote.write(forwarded + rest)
        } catch {
            await remote.close()
            local.close()
            return
        }
        await pump(remote)
    }

    private func readHead() async -> (ProxyRequestHead, Data)? {
        var buffer = Data()
        while true {
            guard let chunk = try? await local.read() else {
                local.close()
                return nil
            }
            buffer.append(chunk)
            do {
                if let split = try ProxyRequestHead.split(buffer) { return split }
            } catch {
                await answer(.badRequest)
                return nil
            }
        }
    }

    private func answer(_ response: ProxyResponse) async {
        try? await local.write(response.encoded)
        await local.finishWriting()
        local.close()
    }

    private func pump(_ remote: any TunnelStream) async {
        let local = local
        await withTaskGroup(of: Bool.self) { group in
            // Browser to machine.
            group.addTask {
                while true {
                    guard let data = try? await local.read() else {
                        await remote.finishWriting()
                        return true
                    }
                    guard (try? await remote.write(data)) != nil else { return false }
                }
            }
            // Machine to browser.
            group.addTask {
                while true {
                    let data: Data?
                    do {
                        data = try await remote.read()
                    } catch {
                        return false
                    }
                    guard let data else {
                        await local.finishWriting()
                        return true
                    }
                    guard (try? await local.write(data)) != nil else { return false }
                }
            }
            var finished = 0
            for await clean in group {
                finished += 1
                if !clean || finished == 2 {
                    await remote.close()
                    local.close()
                }
            }
        }
    }
}
