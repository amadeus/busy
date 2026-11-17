#!/usr/bin/env swift
import AppKit
import WebKit

// Run from the project root: swift scripts/render-icons.swift
// WebKit preserves the SVG filters and alpha that simpler SVG renderers discard.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let icons = root.appendingPathComponent("Resources/Icons", isDirectory: true)
let scratch = root.appendingPathComponent("build/icon-assets", isDirectory: true)
let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let files = FileManager.default
try files.createDirectory(at: iconset, withIntermediateDirectories: true)

func command(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "IconRenderer", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(executable) failed."])
    }
}

final class Renderer: NSObject, WKScriptMessageHandler {
    var webView: WKWebView!

    func start() throws {
        let jobs: [[String: Any]] = try [
            ("AppIcon.svg", "AppIcon.png", 1024),
            ("StatusIcon.svg", "StatusIconTemplate.png", 18),
            ("StatusIcon.svg", "StatusIconTemplate@2x.png", 36),
        ].map { source, output, size in
            let data = try Data(contentsOf: icons.appendingPathComponent(source))
            return ["source": "data:image/svg+xml;base64," + data.base64EncodedString(),
                    "output": output, "size": size]
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: jobs), encoding: .utf8)!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "rendered")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024), configuration: configuration)
        webView.loadHTMLString("""
        <!doctype html><meta charset="utf-8"><script>
        (async () => {
            try {
                const images = [];
                for (const job of \(json)) {
                    const image = new Image();
                    image.src = job.source;
                    await image.decode();
                    const canvas = document.createElement('canvas');
                    canvas.width = canvas.height = job.size;
                    canvas.getContext('2d').drawImage(image, 0, 0, job.size, job.size);
                    images.push({output: job.output, png: canvas.toDataURL('image/png').split(',')[1]});
                }
                window.webkit.messageHandlers.rendered.postMessage({images});
            } catch (error) {
                window.webkit.messageHandlers.rendered.postMessage({error: String(error)});
            }
        })();
        </script>
        """, baseURL: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        do {
            guard let result = message.body as? [String: Any],
                  let images = result["images"] as? [[String: String]] else {
                throw NSError(domain: "IconRenderer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "WebKit failed: \(message.body)"])
            }
            for image in images {
                guard let name = image["output"], let encoded = image["png"],
                      let data = Data(base64Encoded: encoded) else { fatalError("Invalid rendered image") }
                let destination = name == "AppIcon.png" ? scratch : icons
                try data.write(to: destination.appendingPathComponent(name))
            }
            for size in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let pixels = size * scale
                    let suffix = scale == 2 ? "@2x" : ""
                    let output = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                    try command("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)",
                        scratch.appendingPathComponent("AppIcon.png").path, "--out", output.path])
                }
            }
            try command("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icons.appendingPathComponent("AppIcon.icns").path])
            print("Generated AppIcon.icns and 1x/2x menu bar templates in Resources/Icons.")
            exit(0)
        } catch { fail(error.localizedDescription) }
    }
}

func fail(_ message: String) -> Never {
    fputs("Icon renderer: \(message)\n", stderr)
    exit(1)
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let renderer = Renderer()
try renderer.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fail("WebKit did not render within 30 seconds.") }
NSApp.run()
