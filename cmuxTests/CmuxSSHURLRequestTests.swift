import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxSSHURLRequestTests: XCTestCase {
    deinit {}

    var supportedScheme: String {
        AuthEnvironment.callbackScheme
    }

    func parsedOptional(_ url: URL) throws -> CmuxSSHURLRequest? {
        switch CmuxSSHURLRequest.parse(url) {
        case .success(let request):
            return request
        case .failure(let error):
            throw error
        }
    }

    func sshURL(queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = queryItems
        return components.url
    }

    func textURL(host: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = host
        components.queryItems = queryItems
        return components.url
    }
}

