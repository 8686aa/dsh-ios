import Foundation

/// Plain-JSON client for the gateway's `/native/*` surface.
/// Handles the one-time `?k=` login (which sets a long-lived cookie) and the
/// NDJSON stream returned by `/native/ask`.
struct GatewayClient {
    let device: DshDevice

    private var base: URL { device.baseURL ?? URL(string: "http://127.0.0.1")! }

    private var session: URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 900
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = .shared
        cfg.httpCookieAcceptPolicy = .always
        return URLSession(configuration: cfg)
    }

    // MARK: auth

    /// Exchanges `?k=<key>` for the gateway cookie. Safe to call repeatedly.
    func login() async throws {
        guard let key = device.key, !key.isEmpty else { return }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [URLQueryItem(name: "k", value: key)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        _ = try await session.data(for: req)
    }

    // MARK: reads

    func sessions() async throws -> [SessionSummary] {
        let data = try await get(path: "/native/sessions")
        return try JSONDecoder().decode(SessionsResponse.self, from: data).sessions
    }

    func messages(sessionId: String) async throws -> SessionDetail {
        let enc = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        let data = try await get(path: "/native/session/\(enc)/messages")
        return try JSONDecoder().decode(SessionDetail.self, from: data)
    }

    private func get(path: String) async throws -> Data {
        try await login()
        guard let url = URL(string: path, relativeTo: base) else { throw GatewayError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GatewayError.badResponse }
        guard http.statusCode == 200 else { throw GatewayError.status(http.statusCode) }
        return data
    }

    // MARK: ask (streaming)

    func ask(sessionId: String?, text: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await login()
                    var req = URLRequest(url: base.appendingPathComponent("native/ask"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 900
                    var body: [String: String] = ["text": text]
                    if let sessionId, !sessionId.isEmpty { body["sessionId"] = sessionId }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw GatewayError.badResponse }
                    guard http.statusCode == 200 else { throw GatewayError.status(http.statusCode) }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
                        guard let event = try? decoder.decode(StreamEvent.self, from: data) else { continue }
                        continuation.yield(event)
                        if event.type == "done" { break }
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                    else { continuation.finish() }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum GatewayError: LocalizedError {
    case badResponse
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "网关返回了无法识别的响应"
        case .status(let code):
            switch code {
            case 401: return "需要访问密钥（在电脑 ~/.dsh/.phone-key 里）"
            case 404: return "这条会话在电脑上已经不存在"
            default: return "网关返回 HTTP \(code)"
            }
        }
    }
}
