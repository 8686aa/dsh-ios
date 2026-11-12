import SwiftUI

@main
struct DSHPhoneApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
    }
}

/// Glue between discovery, the selected gateway and the current session.
@MainActor
final class AppState: ObservableObject {
    @Published var device: DshDevice? {
        didSet { persistDevice() }
    }
    @Published var sessions: [SessionSummary] = []
    @Published var loadingSessions = false
    @Published var lastError: String?

    @AppStorage("dsh.device.host") private var savedHost = ""
    @AppStorage("dsh.device.port") private var savedPort = 0
    @AppStorage("dsh.device.key") private var savedKey = ""
    @AppStorage("dsh.device.name") private var savedName = ""

    init() {
        if !savedHost.isEmpty, savedPort > 0 {
            device = DshDevice(host: savedHost, port: savedPort, name: savedName, key: savedKey.isEmpty ? nil : savedKey)
        }
    }

    private func persistDevice() {
        savedHost = device?.host ?? ""
        savedPort = device?.port ?? 0
        savedKey = device?.key ?? ""
        savedName = device?.name ?? ""
    }

    private var client: GatewayClient? {
        device.map(GatewayClient.init(device:))
    }

    func connect(_ d: DshDevice) {
        device = d
        Task { await refreshSessions() }
    }

    func disconnect() {
        device = nil
        sessions = []
        lastError = nil
    }

    func refreshSessions() async {
        guard let client else { return }
        loadingSessions = true
        defer { loadingSessions = false }
        do {
            sessions = try await client.sessions()
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func messages(for id: String) async throws -> SessionDetail {
        guard let client else { throw GatewayError.badResponse }
        return try await client.messages(sessionId: id)
    }

    func ask(sessionId: String?, text: String) throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let client else { throw GatewayError.badResponse }
        return client.ask(sessionId: sessionId, text: text)
    }
}
