import Foundation

// MARK: - Discovery

/// One reachable dsh phone gateway on the LAN.
struct DshDevice: Identifiable, Hashable, Codable {
    var host: String
    var port: Int
    var name: String
    var key: String?

    var id: String { "\(host):\(port)" }

    var baseURL: URL? { URL(string: "http://\(host):\(port)") }

    var displayName: String { name.isEmpty ? "\(host):\(port)" : name }

    var subtitle: String { "\(host):\(port)" + (key?.isEmpty == false ? " · key" : "") }
}

/// Payload returned by `GET /__ping?fmt=json`.
struct PingInfo: Decodable {
    var service: String?
    var name: String?
    var version: String?
    var key: String?
    var native: Bool?
    var ports: [Int]?
    var os: String?
}

// MARK: - Gateway payloads

struct SessionSummary: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var cwd: String
    var createdAt: Double
    var updatedAt: Double
    var bytes: Double?

    var displayTitle: String { title.isEmpty ? "(新会话)" : title }
    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    var folderName: String {
        let parts = cwd.split(separator: "\\")
        return parts.last.map(String.init) ?? cwd
    }
}

struct SessionsResponse: Decodable { var sessions: [SessionSummary] }

struct ChatMessage: Decodable, Identifiable, Hashable {
    var kind: String            // user | assistant | tool | turn_end
    var text: String?
    var reasoning: String?
    var callId: String?
    var name: String?
    var args: String?
    var result: String?
    var status: String?
    var turn: Double?
    var step: Double?
    var time: Double?

    var id: String {
        if let c = callId, !c.isEmpty { return "tool-" + c }
        return "\(kind)-\(time ?? 0)-\((text ?? "").hashValue)-\((reasoning ?? "").count)"
    }
}

struct SessionDetail: Decodable {
    var id: String
    var cwd: String
    var createdAt: Double
    var messages: [ChatMessage]
}

// MARK: - Streaming run events

struct StreamEvent: Decodable {
    struct Payload: Decodable {
        var type: String?
        var text: String?
    }
    struct Reason: Decodable {
        var kind: String?
        struct Err: Decodable { var message: String? }
        var error: Err?
    }

    var type: String
    var text: String?
    var phase: String?
    var turn: Double?
    var step: Double?
    var sessionId: String?
    var reason: Reason?
    var data: Payload?
    var code: Double?

    /// best-effort text for `text` / `final` / `thinking` events
    var body: String? {
        if let t = text, !t.isEmpty { return t }
        if let t = data?.text, !t.isEmpty { return t }
        return nil
    }
}
