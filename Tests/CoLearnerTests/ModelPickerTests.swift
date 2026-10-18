import AppKit
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct ModelPickerTests {
    private let fastHint = "Faster responses with the same model and effort; uses your plan limits faster."

    private func config(fast: Bool, effort: String = "high") -> [String: Any] {
        let efforts = [["id": "medium", "label": "Medium"], ["id": "high", "label": "High"]]
        return [
            "codex": ["models": [["id": "gpt-5.4", "label": "GPT-5.4"]], "model": "gpt-5.4",
                      "efforts": efforts, "effort": effort, "fastMode": fast, "fastModeHint": fastHint],
            "claude": ["models": [["id": "opus", "label": "Opus"]], "model": "opus",
                       "efforts": efforts, "effort": effort]
        ]
    }

    private func open(_ provider: String, in web: ChatWebFixture) async throws {
        _ = try await web.evaluate("document.querySelector('.pickbtn.\(provider)').click(); null;")
    }

    @Test func fastModePostsBothStatesAndNativeConfigPreservesFocus() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setProvider", "codex")
        try await web.call("setConfig", config(fast: false))
        try await open("codex", in: web)
        #expect(try await web.evaluate("document.querySelector('#fast-mode').checked") as? Bool == false)
        #expect(try await web.evaluate("document.querySelector('#fast-mode').labels[0].textContent") as? String == "Fast mode")
        #expect(try await web.evaluate("document.getElementById(document.querySelector('#fast-mode').getAttribute('aria-describedby')).textContent") as? String == fastHint)

        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#fast-mode').focus(); document.querySelector('#fast-mode').click(); null;")
        let enabled = try await web.waitForMessage(type: "setFastMode")
        #expect(enabled["provider"] as? String == "codex")
        #expect(enabled["enabled"] as? Bool == true)
        #expect(enabled.count == 3)
        try await web.call("setConfig", config(fast: true))
        #expect(try await web.evaluate("document.querySelector('#fast-mode').checked") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('.pickbtn.codex .pk-fast').textContent") as? String == "Fast")
        #expect(try await web.evaluate("document.activeElement.id") as? String == "fast-mode")
        #expect(try await web.evaluate("document.querySelector('.effort-now').textContent") as? String == "High")

        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#fast-mode').click(); null;")
        let disabled = try await web.waitForMessage(type: "setFastMode")
        #expect(disabled["provider"] as? String == "codex")
        #expect(disabled["enabled"] as? Bool == false)
        try await web.call("setConfig", config(fast: false))
        #expect(try await web.evaluate("document.querySelector('#fast-mode').checked") as? Bool == false)
        #expect(try await web.evaluate("document.querySelector('.pickbtn.codex .pk-fast') === null") as? Bool == true)
        #expect(try await web.evaluate("document.activeElement.id") as? String == "fast-mode")
        #expect(web.messages.allSatisfy { !["setModel", "setEffort"].contains($0["type"] as? String ?? "") })
    }

    @Test func fastModeSurvivesReopenAndStreamingWhileEffortControlsStillWork() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setProvider", "codex")
        try await web.call("setConfig", config(fast: true))
        try await open("codex", in: web)
        try await open("codex", in: web)
        #expect(try await web.evaluate("document.querySelector('.pop').hidden") as? Bool == true)
        try await open("codex", in: web)
        #expect(try await web.evaluate("document.querySelector('#fast-mode').checked") as? Bool == true)

        try await web.call("upsertMessage", ["id": "answer", "role": "assistant", "provider": "codex", "text": "An answer", "status": "streaming"])
        try await web.call("upsertMessage", ["id": "answer", "role": "assistant", "provider": "codex", "text": "An answer in progress", "status": "streaming"])
        try await web.waitFor("document.querySelector('#log .body').textContent.includes('in progress')")
        try await web.call("setConfig", config(fast: true))
        #expect(try await web.evaluate("document.querySelector('#fast-mode').checked && !document.querySelector('.pop').hidden") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('.pickbtn.codex .pk-fast').textContent") as? String == "Fast")

        web.clearMessages()
        _ = try await web.evaluate("var range = document.querySelector('.slider input'); range.focus(); range.value = '0'; range.dispatchEvent(new Event('input')); range.dispatchEvent(new Event('change')); null;")
        let effort = try await web.waitForMessage(type: "setEffort")
        #expect(effort["provider"] as? String == "codex")
        #expect(effort["effort"] as? String == "medium")
        try await web.call("setConfig", config(fast: true, effort: "medium"))
        #expect(try await web.evaluate("document.activeElement.type") as? String == "range")
        #expect(try await web.evaluate("document.querySelector('.slider input').value") as? String == "0")
        #expect(try await web.evaluate("document.querySelector('#fast-mode').checked") as? Bool == true)

        // A config refresh must wait until the current slider drag completes.
        _ = try await web.evaluate("window.draggedRange = document.querySelector('.slider input'); window.draggedRange.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true})); null;")
        try await web.call("setConfig", config(fast: false, effort: "medium"))
        #expect(try await web.evaluate("document.querySelector('.slider input') === window.draggedRange") as? Bool == true)
        _ = try await web.evaluate("document.dispatchEvent(new PointerEvent('pointerup', {bubbles:true})); null;")
        #expect(try await web.evaluate("document.querySelector('.slider input') !== window.draggedRange") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('#fast-mode').checked") as? Bool == false)
        #expect(try await web.evaluate("document.activeElement.type") as? String == "range")
    }

    @Test func claudeMenuDoesNotOfferFastMode() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setProvider", "both")
        try await web.call("setConfig", config(fast: true))
        try await open("claude", in: web)
        #expect(try await web.evaluate("document.querySelector('#fast-mode') === null") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('.pickbtn.claude .pk-fast') === null") as? Bool == true)
        #expect(try await web.evaluate("document.querySelectorAll('.pickbtn.codex .pk-fast').length") as? Int == 1)
        try await open("codex", in: web)
        #expect(try await web.evaluate("document.querySelector('#fast-mode').checked") as? Bool == true)
    }

    @Test func fastModeFitsNarrowChatPanel() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        web.webView.frame.size = NSSize(width: 420, height: 700)
        try await web.load()
        try await web.call("setProvider", "both")
        try await web.call("setConfig", config(fast: true))
        try await open("codex", in: web)
        #expect(try await web.evaluate("document.documentElement.scrollWidth <= window.innerWidth") as? Bool == true)
        #expect(try await web.evaluate("Array.from(document.querySelectorAll('.pickbtn, #btn-send, .pop, .fast-mode, #fast-mode-hint')).every(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.left >= 0 && r.right <= window.innerWidth && r.top >= 0 && r.bottom <= window.innerHeight; })") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('.pop').scrollWidth <= document.querySelector('.pop').clientWidth") as? Bool == true)
        if ProcessInfo.processInfo.environment["COLEARNER_TEST_SNAPSHOTS"] != nil {
            try await web.snapshot(to: URL(fileURLWithPath: "/tmp/colearner-v018-fast-mode.png"))
        }
    }
}
