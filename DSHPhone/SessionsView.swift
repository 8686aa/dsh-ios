import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var app: AppState
    @State private var newChat = false

    var body: some View {
        NavigationStack {
            List {
                if let err = app.lastError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach(app.sessions) { session in
                        NavigationLink {
                            ChatView(session: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.displayTitle)
                                    .font(.body.weight(.medium))
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(session.folderName)
                                    Text("·")
                                    Text(session.updatedDate, style: .relative)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text("会话")
                        Spacer()
                        if app.loadingSessions { ProgressView().scaleEffect(0.7) }
                    }
                }
            }
            .navigationTitle(app.device?.displayName ?? "dsh")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await app.refreshSessions() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("断开") { app.disconnect() }
                        .font(.caption)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newChat = true
                    } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .task {
                if app.sessions.isEmpty { await app.refreshSessions() }
            }
            .navigationDestination(isPresented: $newChat) {
                ChatView(session: nil)
            }
        }
    }
}
