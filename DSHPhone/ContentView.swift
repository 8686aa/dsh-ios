import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var discovery: DiscoveryService
    @State private var showManual = false
    @State private var route: DshDevice?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if discovery.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(discovery.isScanning ? "正在扫描局域网…" : "还没发现设备")
                                .font(.headline)
                            Text("确认手机和电脑连的是同一个 Wi-Fi，且电脑上的 dsh 网关已启动。也可以手动添加 IP。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(discovery.devices) { device in
                        NavigationLink(value: device) {
                            DeviceRow(device: device)
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { discovery.forget(discovery.devices[i]) }
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
                        Label("手动添加地址", systemImage: "plus.circle")
                    }
                } footer: {
                    Text(discovery.statusText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("dsh")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let ip = discovery.localAddress {
                        Text(ip).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showManual = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: DshDevice.self) { device in
                WebPane(device: device)
            }
            .sheet(isPresented: $showManual) {
                ManualAddView { host, port, key in
                    discovery.addManual(host: host, port: port, key: key)
                }
            }
            .refreshable { discovery.rescan() }
        }
    }
}

struct DeviceRow: View {
    let device: DshDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(device.displayName).font(.body.weight(.medium))
            HStack(spacing: 6) {
                Text("\(device.host):\(device.port)")
                if device.key != nil {
                    Image(systemName: "key.fill").font(.caption2)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("访问密钥") {
                    TextField("可留空", text: $key)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("电脑上 ~/.dsh/.phone-key 里的内容，或网关启动日志里 access key 那行。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("手动添加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let p = Int(port) ?? 8080
                        onAdd(host.trimmingCharacters(in: .whitespaces), p, key.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(host.isEmpty)
                }
            }
        }
    }
}
