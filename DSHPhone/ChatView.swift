import SwiftUI

struct ChatView: View {
    let session: SessionSummary?

    @EnvironmentObject private var app: AppState

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var loading = false
    @State private var running = false
    @State private var liveText = ""
    @State private var liveReasoning = ""
    @State private var statusLine = ""
    @State private var errorText: String?
    @State private var sessionId: String?
    @State private var runTask: Task<Void, Never>?

    private var currentId: String? { sessionId ?? session?.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if loading && messages.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }

                    ForEach(messages) { msg in
                        MessageRow(message: msg).id(msg.id)
                    }

                    if running || !liveText.isEmpty || !liveReasoning.isEmpty {
                        LiveRow(text: liveText, reasoning: liveReasoning, status: statusLine)
                            .id("live")
                    }

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: liveText.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(session?.displayTitle ?? "新会话")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { composer }
        .task { await reload() }
        .onDisappear { runTask?.cancel() }
    }

    // MARK: composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("发消息…", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))

                Button {
                    send()
                } label: {
                    Image(systemName: running ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend || running ? Color.accentColor : Color.secondary)
                }
                .disabled(!canSend && !running)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !running
    }

    // MARK: actions

    private func send() {
        if running {
            runTask?.cancel()
            running = false
            return
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        running = true
        liveText = ""
        liveReasoning = ""
        errorText = nil
        statusLine = "发送中…"

        runTask = Task {
            do {
                let stream = try app.ask(sessionId: currentId, text: text)
                for try await ev in stream {
                    if Task.isCancelled { break }
                    switch ev.type {
                    case "session":
                        if let sid = ev.sessionId { sessionId = sid }
                    case "status":
                        if let phase = ev.phase {
                            statusLine = phase == "turn_end" ? "" : phase
                        }
                        if let err = ev.reason?.error?.message, !err.isEmpty { errorText = err }
                    case "thinking":
                        if let body = ev.body { liveReasoning += body }
                    case "text":
                        if let body = ev.body { liveText += body }
                    case "final":
                        if let t = ev.text, !t.isEmpty { liveText = t }
                    case "done":
                        if let code = ev.code, code != 0, errorText == nil {
                            errorText = "运行结束，退出码 \(Int(code))"
                        }
                    case "log":
                        if liveText.isEmpty, let t = ev.data?.text, !t.isEmpty {
                            statusLine = String(t.prefix(120))
                        }
                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            running = false
            statusLine = ""
            liveReasoning = ""
            if liveText.isEmpty || Task.isCancelled {
                liveText = ""
            }
            await reload()
            liveText = ""
        }
    }

    private func reload() async {
        guard let id = currentId else { return }
        loading = true
        defer { loading = false }
        do {
            let detail = try await app.messages(for: id)
            messages = detail.messages.filter { $0.kind != "turn_end" || false }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Rows

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.kind {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(message.text ?? "")
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            }
        case "assistant":
            VStack(alignment: .leading, spacing: 6) {
                if let r = message.reasoning, !r.isEmpty {
                    DisclosureGroup("思考") {
                        Text(r)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
                if let t = message.text, !t.isEmpty {
                    MarkdownText(text: t)
                } else if (message.reasoning ?? "").isEmpty {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case "tool":
            ToolRow(message: message)
        default:
            EmptyView()
        }
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ToolRow: View {
    let message: ChatMessage
    @State private var expanded = false

    private var isDone: Bool { (message.status ?? "") == "done" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isDone ? "checkmark.circle" : "circle.dotted")
                        .font(.caption)
                        .foregroundStyle(isDone ? Color.green : Color.orange)
                    Text(message.name ?? "tool")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let a = message.args, !a.isEmpty {
                        Text(a)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(12)
                    }
                    if let r = message.result, !r.isEmpty {
                        Text(r)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(40)
                    }
                }
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LiveRow: View {
    let text: String
    let reasoning: String
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !reasoning.isEmpty {
                DisclosureGroup("思考中…") {
                    Text(reasoning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            if text.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(status.isEmpty ? "运行中…" : status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                MarkdownText(text: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
