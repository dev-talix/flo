import AppKit
import SwiftUI
import XCTest
@testable import LocalFlow

@MainActor
final class SettingsWindowEditingTests: XCTestCase {
    private final class Editor: NSTextView {
        var pasteCount = 0
        var copyCount = 0
        var cutCount = 0

        override func paste(_ sender: Any?) {
            pasteCount += 1
            insertText("let sample = \"new line\";\n// second line", replacementRange: selectedRange())
        }

        override func copy(_ sender: Any?) { copyCount += 1 }
        override func cut(_ sender: Any?) { cutCount += 1 }
    }

    func testCommandPasteReplacesTheSelectionWithMultilineTextWithoutReadingTheClipboard() throws {
        let (window, editor) = makeEditor()
        editor.string = "replace this"
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))

        XCTAssertTrue(window.performKeyEquivalent(with: try key("v", code: 9)))

        XCTAssertEqual(editor.pasteCount, 1)
        XCTAssertEqual(editor.string, "let sample = \"new line\";\n// second line")
    }

    func testStandardEditingShortcutsReachTheFocusedEditor() throws {
        let (window, editor) = makeEditor()
        editor.string = "select all of this"

        XCTAssertTrue(window.performKeyEquivalent(with: try key("c", code: 8)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key("x", code: 7)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key("a", code: 0)))

        XCTAssertEqual(editor.copyCount, 1)
        XCTAssertEqual(editor.cutCount, 1)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
    }

    func testOtherModifiersAndOrdinaryTypingDoNotInvokePaste() throws {
        let (window, editor) = makeEditor()
        for modifiers: NSEvent.ModifierFlags in [[], [.command, .option], [.command, .shift], [.control]] {
            XCTAssertFalse(window.performKeyEquivalent(with: try key("v", code: 9, modifiers: modifiers)))
        }
        XCTAssertEqual(editor.pasteCount, 0)
    }

    func testAnUnfocusedEditingCommandIsNotClaimed() throws {
        _ = NSApplication.shared
        let window = SettingsWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertFalse(window.performKeyEquivalent(with: try key("v", code: 9)))
    }

    func testRenderSnippetForm() throws {
        guard let directory = ProcessInfo.processInfo.environment["FLO_SNIPPET_RENDER_DIR"] else {
            throw XCTSkip("Set FLO_SNIPPET_RENDER_DIR to write native snippet form renders")
        }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            for width: CGFloat in [420, 540] {
                for state in ["empty", "filled", "long"] {
                    let expansion = state == "empty" ? "" : state == "long"
                        ? String(repeating: "A longer pasted snippet keeps its line breaks and scrolls inside this field.\n", count: 12)
                        : "let sample = \"new line\";\n// first, second, thumbs up emoji"
                    let form = Form {
                        Section {
                            NewSnippetForm(
                                trigger: .constant(state == "empty" ? "" : "insert practice code"),
                                expansion: .constant(expansion),
                                add: {}
                            )
                        } header: {
                            Text("Snippets")
                        } footer: {
                            Text("The spoken phrase must match your words; capitalization is ignored. Its saved text is inserted exactly, even with Literal formatting on.")
                        }
                    }
                    .formStyle(.grouped)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: width, height: 360)
                    let host = NSHostingView(rootView: form)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 360),
                                                styleMask: .borderless, backing: .buffered, defer: false)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "snippet-\(dark ? "dark" : "light")-\(Int(width))-\(state).png"
                    try image.write(to: folder.appendingPathComponent(name))
                }
            }
        }
    }

    private func makeEditor() -> (SettingsWindow, Editor) {
        _ = NSApplication.shared
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        let editor = Editor(frame: window.contentView!.bounds)
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        return (window, editor)
    }

    private func key(_ characters: String, code: UInt16,
                     modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }
}
