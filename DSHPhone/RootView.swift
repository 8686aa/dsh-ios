import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var discovery = DiscoveryService()

    var body: some View {
        Group {
            if app.device != nil {
                SessionsView()
            } else {
                DevicePickerView()
            }
        }
        .environmentObject(discovery)
        .onAppear { discovery.start() }
    }
}

// MARK: - Device picker

struct DevicePickerView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var discovery: DiscoveryService

    @State private var showManual = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if discovery.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(discovery.isScanning ? "正在扫描局域网…" : "还没发现网关")
                                .font(.headline)
                            Text("电脑上先运行 dsh 手机网关，并确认手机与电脑在同一个 Wi-Fi。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(discovery.devices) { device in
                        Button {
                            app.connect(device)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.displayName).font(.body.weight(.medium))
                                    Text(device.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("局域网设备")
                }

                Section {
                    Button {
                        discovery.rescan()
                    } label: {
                        HStack {
                            Label("重新扫描", systemImage: "arrow.clockwise")
                            Spacer()
                            if discovery.isScanning { ProgressView() }
                        }
                    }
                    Button {
                        showManual = true
                    } label: {
                        Label("手动输入地址", systemImage: "plus.circle")
                    }
                    if let diag = discovery.diagnostics {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("诊断").font(.caption.weight(.semibold))
                            Text(diag).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text(discovery.statusText).font(.footnote)
                }
            }
            .navigationTitle("dsh")
            .refreshable { discovery.rescan() }
            .sheet(isPresented: $showManual) {
                ManualAddView { host, port, key in
                    app.connect(DshDevice(host: host, port: port, name: "手动 · \(host)", key: key.isEmpty ? nil : key))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        discovery.rescan()
                    } label: { Image(systemName: "antenna.radiowaves.left.and.right") }
                }
            }
        }
    }
}

struct ManualAddView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "8080"
    @State private var key = ""

    var onAdd: (String, Int, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("地址") {
                    TextField("192.168.5.120", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("端口", text: $port).keyboardType(.numberPad)
                }
                Section("访问密钥") {
                    TextField("可留空", text: $key)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("电脑上 ~/.dsh/.phone-key 的内容，或网关启动日志里 access key 那一行。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("手动添加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        onAdd(host.trimmingCharacters(in: .whitespaces),
                              Int(port) ?? 8080,
                              key.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(host.isEmpty)
                }
            }
        }
    }
}
