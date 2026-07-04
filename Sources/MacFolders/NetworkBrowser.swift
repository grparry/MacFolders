import Foundation
import Network

/// App-wide Bonjour browser for SMB servers on the local network.
/// Sidebars render `servers` under Locations and re-render on the
/// `serversChanged` notification.
final class NetworkBrowser {
    static let shared = NetworkBrowser()
    static let serversChanged = Notification.Name("NetworkBrowserServersChanged")

    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private(set) var servers: [String] = []

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil),
                                using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [String: NWEndpoint] = [:]
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    found[name] = result.endpoint
                }
            }
            DispatchQueue.main.async {
                self.endpoints = found
                self.servers = found.keys.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                NotificationCenter.default.post(name: Self.serversChanged, object: nil)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Resolve a discovered server to a connectable host string. Bonjour
    /// service names are display names, not hostnames — a brief TCP dial
    /// yields the real remote endpoint.
    func resolveHost(of name: String, completion: @escaping (String?) -> Void) {
        guard let endpoint = endpoints[name] else {
            completion(nil)
            return
        }
        let connection = NWConnection(to: endpoint, using: .tcp)
        var finished = false
        let finish: (String?) -> Void = { host in
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(host)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint {
                    switch host {
                    case .name(let hostname, _): finish(hostname)
                    case .ipv4(let address): finish("\(address)")
                    case .ipv6(let address): finish("[\(address)]")
                    @unknown default: finish(nil)
                    }
                } else {
                    finish(nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}
