import Foundation

/// One reachable dsh phone gateway on the LAN.
struct DshDevice: Identifiable, Hashable, Codable {
    var host: String
    var port: Int
    var name: String
    var key: String?

    var id: String { "\(host):\(port)" }

    var baseURL: URL? { URL(string: "http://\(host):\(port)") }

    /// URL that carries the access key once, so the gateway can set its cookie.
    var loginURL: URL? {
        guard let base = baseURL else { return nil }
        guard let k = key, !k.isEmpty else { return base }
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        c.queryItems = [URLQueryItem(name: "k", value: k)]
        return c.url
    }

    var displayName: String {
        name.isEmpty ? "\(host):\(port)" : name
    }
}

/// Payload returned by the gateway's `/__ping?fmt=json`.
struct PingInfo: Decodable {
    var service: String?
    var name: String?
    var version: String?
    var key: String?
    var ports: [Int]?
    var os: String?
}
