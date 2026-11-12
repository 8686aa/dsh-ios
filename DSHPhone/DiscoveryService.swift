import Foundation
import Network
import Darwin

/// Discovers dsh phone gateways on the local network in two independent ways:
///   1. Bonjour (`_dsh._tcp`) — instant when the gateway announces itself.
///   2. A parallel /24 sweep of `/__ping?fmt=json` — works even without mDNS.
@MainActor
final class DiscoveryService: NSObject, ObservableObject {

    @Published private(set) var devices: [DshDevice] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var statusText: String = "就绪"
    @Published private(set) var localAddress: String?

    private var browser: NWBrowser?
    private var services: [String: NetService] = [:]
    private var bonjourHits: Set<String> = []
    private var sweepTask: Task<Void, Never>?

    private static let scanPorts = [80, 8080]
    private static let storeKey = "dsh.known.devices"

    private let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.9
        cfg.timeoutIntervalForResource = 1.5
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg)
    }()

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([DshDevice].self, from: data) {
            devices = saved
        }
    }

    // MARK: - lifecycle

    func start() {
        localAddress = Self.currentIPv4()
        statusText = "本机 \(localAddress ?? "?")，正在发现…"
        startBonjour()
        rescan()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        sweepTask?.cancel()
        sweepTask = nil
        for (_, s) in services { s.stop() }
        services.removeAll()
    }

    func rescan() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            await self?.sweep()
        }
    }

    // MARK: - manual add

    func addManual(host: String, port: Int, key: String) {
        let d = DshDevice(host: host, port: port, name: "手动 · \(host)", key: key.isEmpty ? nil : key)
        merge(d)
        statusText = "已添加手动地址"
    }

    func forget(_ device: DshDevice) {
        devices.removeAll { $0.id == device.id }
        persist()
    }

    // MARK: - bonjour

    private func startBonjour() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_dsh._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let err) = state {
                    self.statusText = "Bonjour 不可用：\(err.localizedDescription)"
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.absorbBonjour(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func absorbBonjour(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else { continue }
            let token = "bonjour:\(name)"
            if bonjourHits.contains(token) { continue }
            bonjourHits.insert(token)

            let svc = NetService(domain: "local.", type: "_dsh._tcp.", name: name)
            svc.delegate = self
            svc.schedule(in: .main, forMode: .common)
            svc.resolve(withTimeout: 4)
            services[token] = svc
        }
    }

    private func bonjourResolved(name: String, host: String, port: Int, txt: [String: Data]) {
        var key: String?
        if let raw = txt["key"], let s = String(data: raw, encoding: .utf8), !s.isEmpty {
            key = s
        }
        let label = String(data: txt["name"] ?? Data(), encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? name
        merge(DshDevice(host: host, port: port, name: label, key: key))
    }

    // MARK: - sweep

    private func sweep() async {
        guard let ip = localAddress ?? Self.currentIPv4() else {
            statusText = "拿不到本机 IP（Wi-Fi 是否已连接？）"
            return
        }
        localAddress = ip
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"

        isScanning = true
        statusText = "扫描 \(prefix).0/24 …"

        let found = await Self.probeAll(prefix: prefix, ports: Self.scanPorts, maxConcurrent: 64)

        isScanning = false
        guard !Task.isCancelled else { return }
        for device in found { merge(device) }
        statusText = found.isEmpty
            ? "没扫到 dsh 网关（已有 \(devices.count) 个已知）"
            : "扫描完成，共 \(devices.count) 个设备"
        persist()
    }

    /// Parallel /24 sweep. Pure `nonisolated` so it never touches the main actor.
    private nonisolated static func probeAll(prefix: String,
                                             ports: [Int],
                                             maxConcurrent: Int) async -> [DshDevice] {
        var queue: [(String, Int)] = []
        queue.reserveCapacity(254 * ports.count)
        // gateway address first: it is by far the most likely host
        for port in ports { queue.append(("\(prefix).1", port)) }
        for last in 2...254 {
            for port in ports { queue.append(("\(prefix).\(last)", port)) }
        }

        var results: [DshDevice] = []
        var iterator = queue.makeIterator()

        await withTaskGroup(of: DshDevice?.self) { group in
            for _ in 0..<maxConcurrent {
                guard let job = iterator.next() else { break }
                group.addTask { await probe(host: job.0, port: job.1) }
            }
            while let result = await group.next() {
                if let device = result { results.append(device) }
                if Task.isCancelled { group.cancelAll(); break }
                if let job = iterator.next() {
                    group.addTask { await probe(host: job.0, port: job.1) }
                }
            }
        }
        return results
    }

    private nonisolated static func probe(host: String, port: Int) async -> DshDevice? {
        guard let url = URL(string: "http://\(host):\(port)/__ping?fmt=json") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.9
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("dsh-ios", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await sharedProbeSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let info = try? JSONDecoder().decode(PingInfo.self, from: data)
            guard info?.service == "dsh-phone-gateway" else { return nil }
            let label = info?.name ?? "dsh @\(host)"
            return DshDevice(host: host, port: port, name: label, key: info?.key)
        } catch {
            return nil
        }
    }

    nonisolated private static let sharedProbeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.9
        cfg.timeoutIntervalForResource = 1.5
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg)
    }()

    // MARK: - merge / persist

    private func merge(_ device: DshDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            let old = devices[idx]
            // keep a user-supplied key if the probe had none
            devices[idx] = DshDevice(
                host: device.host,
                port: device.port,
                name: device.name.isEmpty ? old.name : device.name,
                key: device.key ?? old.key
            )
        } else {
            devices.append(device)
        }
        devices.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    // MARK: - helpers

    static func currentIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                 &hostname, socklen_t(hostname.count),
                                 nil, 0, NI_NUMERICHOST)
            if rc == 0 {
                let s = String(cString: hostname)
                if !s.isEmpty { address = s }
            }
        }
        return address
    }
}

// MARK: - NetServiceDelegate

extension DiscoveryService: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let port = sender.port
        var txt: [String: Data] = [:]
        if let raw = sender.txtRecordData() {
            for (k, v) in NetService.dictionary(fromTXTRecord: raw) { txt[k] = v }
        }
        var host: String?
        if let addrs = sender.addresses {
            for data in addrs {
                host = data.withUnsafeBytes { ptr -> String? in
                    guard let base = ptr.baseAddress else { return nil }
                    var storage = sockaddr_storage()
                    memcpy(&storage, base, min(ptr.count, MemoryLayout<sockaddr_storage>.size))
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let rc = withUnsafePointer(to: &storage) { sp -> Int32 in
                        sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                        &buf, socklen_t(buf.count),
                                        nil, 0, NI_NUMERICHOST)
                        }
                    }
                    return rc == 0 ? String(cString: buf) : nil
                }
                if host != nil { break }
            }
        }
        guard let resolved = host, port > 0 else { return }
        Task { @MainActor in
            self.bonjourResolved(name: name, host: resolved, port: port, txt: txt)
        }
    }
}
