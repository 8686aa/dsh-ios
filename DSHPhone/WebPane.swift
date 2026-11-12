import SwiftUI
import WebKit

/// WKWebView host that keeps the gateway cookie and allows LAN HTTP.
struct WebPane: View {
    let device: DshDevice

    @State private var progress: Double = 0
    @State private var reloadToken = 0
    @State private var failed: String?

    var body: some View {
        ZStack(alignment: .top) {
            WebView(url: device.loginURL,
                    reloadToken: reloadToken,
                    progress: $progress,
                    failed: $failed)
                .ignoresSafeArea(edges: .bottom)

            if progress > 0 && progress < 1 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }

            if let failed {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                    Text(failed).multilineTextAlignment(.center)
                    Button("重试") {
                        self.failed = nil
                        reloadToken += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL?
    let reloadToken: Int
    @Binding var progress: Double
    @Binding var failed: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // persistent cookies for the access key
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.keyboardDismissMode = .interactive
        if #available(iOS 16.4, *) {
            web.isInspectable = true
        }

        context.coordinator.observe(web)
        context.coordinator.loadedToken = reloadToken
        if let url { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedToken != reloadToken else { return }
        context.coordinator.loadedToken = reloadToken
        if let url { web.load(URLRequest(url: url)) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: WebView
        var loadedToken = -1
        private var observers: [NSKeyValueObservation] = []

        init(_ parent: WebView) {
            self.parent = parent
        }

        func observe(_ web: WKWebView) {
            observers.append(web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { self?.parent.progress = w.estimatedProgress }
            })
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.progress = 0
                self.parent.failed = nil
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            let ns = error as NSError
            // -999 is "cancelled", which happens on redirects we cause ourselves
            guard ns.code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async {
                self.parent.failed = "加载失败：\(ns.localizedDescription)\n确认 dsh 网关在电脑上运行，且手机与电脑同一 Wi-Fi。"
            }
        }

        // dsh uses no popups, but keep target=_blank links inside the same view
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
