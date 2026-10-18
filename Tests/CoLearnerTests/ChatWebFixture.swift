import AppKit
import Foundation
import WebKit

/// Runs the shipped chat frontend without ChatController, CLI tools, persistent browser data or AI calls.
@MainActor
final class ChatWebFixture: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private(set) var messages: [[String: Any]] = []
    private(set) var javaScriptErrors: [String] = []
    private var loading: CheckedContinuation<Void, Error>?
    private var loadTimeout: Task<Void, Never>?

    static var webFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CoLearner/Web")
    }

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // An unattached test view can suppress animation frames. Preserve the asynchronous boundary
        // while letting the actual frontend's batched updates run deterministically without a window.
        config.userContentController.addUserScript(WKUserScript(source:
            "window.requestAnimationFrame = function(fn) { return setTimeout(function() { fn(performance.now()); }, 0); };",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        super.init()
        webView.navigationDelegate = self
        config.userContentController.add(self, name: "cl")
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            loadTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.fail(FixtureError.timeout("loading chat.html"))
                self?.webView.stopLoading()
            }
            webView.loadFileURL(Self.webFolder.appendingPathComponent("chat.html"), allowingReadAccessTo: Self.webFolder)
        }
        try await waitFor("!!window.CL && !!window.CLRender")
    }

    func close() {
        fail(FixtureError.closed)
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cl")
        webView.navigationDelegate = nil
    }

    func clearMessages() { messages.removeAll() }

    func snapshot(to url: URL) async throws {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw FixtureError.invalidSnapshot }
        try png.write(to: url)
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func call(_ method: String, _ argument: Any) async throws {
        let json = try JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed])
        _ = try await evaluate("CL.\(method)(\(String(decoding: json, as: UTF8.self))); null;")
    }

    func waitFor(_ condition: String) async throws {
        for _ in 0..<100 {
            if try await evaluate(condition) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.timeout(condition)
    }

    func waitForMessage(type: String) async throws -> [String: Any] {
        for _ in 0..<100 {
            if let message = messages.last(where: { $0["type"] as? String == type }) { return message }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.timeout("native message: \(type)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let continuation = loading
        loading = nil
        loadTimeout?.cancel()
        loadTimeout = nil
        continuation?.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    private func fail(_ error: Error) {
        let continuation = loading
        loading = nil
        loadTimeout?.cancel()
        loadTimeout = nil
        continuation?.resume(throwing: error)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.frameInfo.isMainFrame, let body = message.body as? [String: Any] {
            messages.append(body)
            if body["type"] as? String == "jsError" { javaScriptErrors.append(body["message"] as? String ?? "Unknown JavaScript error") }
        }
    }

    enum FixtureError: Error { case timeout(String), closed, invalidSnapshot }
}
