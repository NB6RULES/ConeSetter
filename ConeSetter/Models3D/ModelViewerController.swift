import Foundation
import SwiftUI
import UIKit
import WebKit
import UniformTypeIdentifiers

/// Serves the bundled viewer (HTML, JS, WASM) and the model being viewed to the web view
/// under csviewer://app/…, so everything works offline and no file has to be base64-bridged.
final class ViewerSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "csviewer"
    var modelURL: URL?
    private let bundleRoot = Bundle.main.resourceURL?.appendingPathComponent("Viewer", isDirectory: true)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        var fileURL: URL?
        if path.hasPrefix("/__model/") {
            fileURL = modelURL
        } else if let root = bundleRoot, !path.contains("..") {
            fileURL = root.appendingPathComponent(String(path.dropFirst()))
        }
        guard let file = fileURL, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let headers = [
            "Content-Type": Self.mime(for: file.pathExtension, isModel: path.hasPrefix("/__model/")),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mime(for ext: String, isModel: Bool) -> String {
        if isModel { return "application/octet-stream" }
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}

/// Keeps the web view's message handler from retaining the controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: ModelViewerController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message.body)
    }
}

enum ViewerPhase: Equatable {
    case loading
    case ready
    case failed(String)
}

@MainActor
final class ModelViewerController: NSObject, ObservableObject, WKNavigationDelegate {
    let item: ModelItem
    let webView: WKWebView

    @Published private(set) var phase: ViewerPhase = .loading
    @Published private(set) var info: ModelInfo?
    @Published var edges = true { didSet { if oldValue != edges { run("CS.setEdges(\(edges))") } } }
    @Published var orthographic = false {
        didSet { if oldValue != orthographic, !syncing { run("CS.setProjection('\(orthographic ? "orthographic" : "perspective")')") } }
    }
    @Published var zUp = false { didSet { if oldValue != zUp, !syncing { run("CS.setUp('\(zUp ? "Z" : "Y")')") } } }

    private let handler = ViewerSchemeHandler()
    private let bridge = WeakMessageHandler()
    private var syncing = false
    private var pageReady = false
    private var started = Date()

    init(item: ModelItem) {
        self.item = item
        handler.modelURL = item.fileURL

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: ViewerSchemeHandler.scheme)
        config.userContentController.add(bridge, name: "cs")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        bridge.target = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 13 / 255, green: 14 / 255, blue: 17 / 255, alpha: 1)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        info = ModelLibrary.shared.info(for: item)

        if let url = URL(string: "\(ViewerSchemeHandler.scheme)://app/viewer.html") {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: Commands

    func setView(_ name: String) { run("CS.setView('\(name)')") }
    func fit() { run("CS.fit()") }

    func reload() {
        phase = .loading
        started = Date()
        if pageReady { loadModel() } else { webView.reload() }
    }

    private func run(_ js: String) {
        guard pageReady else { return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func loadModel() {
        started = Date()
        let encoded = item.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "model"
        webView.callAsyncJavaScript("CS.load(url, name)",
                                    arguments: ["url": "__model/\(encoded)", "name": item.name],
                                    in: nil, in: .page, completionHandler: nil)
    }

    // MARK: Messages from the page

    fileprivate func handle(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            loadModel()
        case "loaded":
            if let d = dict["info"] as? [String: Any] {
                let parsed = ModelInfo(dictionary: d)
                info = parsed
                ModelLibrary.shared.saveInfo(parsed, for: item)
                syncing = true
                zUp = (d["up"] as? String) == "Z"
                orthographic = (dict["projection"] as? String) == "orthographic"
                syncing = false
            }
            if let thumb = dict["thumbnail"] as? String, let comma = thumb.firstIndex(of: ","),
               let png = Data(base64Encoded: String(thumb[thumb.index(after: comma)...])) {
                ModelLibrary.shared.saveThumbnail(png, for: item)
            }
            phase = .ready
            Haptics.tick()
        case "info":
            if let d = dict["info"] as? [String: Any] { info = ModelInfo(dictionary: d) }
        case "error":
            phase = .failed(dict["message"] as? String ?? "The file could not be read.")
            Haptics.error()
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        phase = .failed("The viewer ran out of memory on this file. Very large assemblies may be too big for the phone — try exporting a single part, or a coarser STL.")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        phase = .failed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        phase = .failed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == ViewerSchemeHandler.scheme ? .allow : .cancel
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
