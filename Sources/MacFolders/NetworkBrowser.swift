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

    /// Resolve a discovered server to a connectable hostname. Bonjour
    /// service names are display names, not hostnames — an mDNS SRV
    /// resolution yields the real ".local" host.
    func resolveHost(of name: String, completion: @escaping (String?) -> Void) {
        let resolver = ServiceResolver()
        activeResolvers.append(resolver)
        resolver.resolve(name: name) { [weak self] host in
            self?.activeResolvers.removeAll { $0 === resolver }
            completion(host)
        }
    }

    private var activeResolvers: [ServiceResolver] = []
}

/// One-shot mDNS resolver for an _smb._tcp service instance.
private final class ServiceResolver: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var completion: ((String?) -> Void)?

    func resolve(name: String, completion: @escaping (String?) -> Void) {
        self.completion = completion
        let service = NetService(domain: "local.", type: "_smb._tcp.", name: name)
        service.delegate = self
        self.service = service
        service.resolve(withTimeout: 5)
    }

    private func finish(_ host: String?) {
        completion?(host)
        completion = nil
        service?.stop()
        service = nil
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName?.hasSuffix(".") == true
            ? String(sender.hostName!.dropLast()) : sender.hostName
        finish(host)
    }

    func netService(_ sender: NetService,
                    didNotResolve errorDict: [String: NSNumber]) {
        finish(nil)
    }
}
