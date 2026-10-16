import AppKit
import Carbon.HIToolbox

/// Inserts text into whatever app has focus.
///
/// Default strategy (per plan): put the text on the clipboard, synthesize
/// Cmd+V, then restore the previous clipboard contents. Falls back to
/// synthesized unicode keystrokes when Secure Input is active (password
/// fields block synthesized paste but sometimes accept typed events — and
/// we must never leave dictated text on the clipboard in that case).
@MainActor
enum TextInjector {
    enum InjectionResult: Equatable {
        /// Events were posted. The target app's insertion is not observable.
        case dispatched
        /// Paste was posted, but the clipboard changed before restoration.
        case clipboardChanged
        /// Some or all keyboard events could not be created.
        case dispatchFailed
        case targetChanged

        var userFacingIssue: UserFacingIssue? {
            switch self {
            case .dispatched:
                return nil
            case .clipboardChanged:
                return UserFacingIssue(
                    summary: "Clipboard changed after paste",
                    details: "The paste shortcut was sent, but the clipboard changed before restoration. Check whether the text appeared before copying it from Recent Dictations."
                )
            case .targetChanged:
                return UserFacingIssue(
                    summary: "Voice edit target changed",
                    details: "The original app, text field, or selection changed. Nothing was sent. Copy the result from Recent Dictations to use it."
                )
            case .dispatchFailed:
                return UserFacingIssue(
                    summary: "Couldn't send dictation",
                    details: "Some or all text could not be sent. Check the target app before copying the transcript from Recent Dictations."
                )
            }
        }
    }

    // All mutated on the main thread only (inject is called from the app's
    // main-actor pipeline). Tracks one save/restore cycle across possibly
    // overlapping dictations.
    private static var savedItems: [NSPasteboardItem]?
    private static var restoreWork: DispatchWorkItem?
    private static var pendingCompletion: ((_ undisturbed: Bool, _ readObserved: Bool) -> Void)?
    private static var pendingReady: (() -> Void)?
    private static var ourChangeCount = -1
    private static var restoreGeneration = 0
    private static var dispatchedAt: TimeInterval?
    private static var readObservedAt: TimeInterval?
    // AppKit's docs don't promise the item keeps its provider alive.
    private static var pasteReceipt: PasteReceipt?

    /// When to put the user's clipboard back. Restore at the later of
    /// read + `grace` and dispatch + `floor`. With no read, restore at
    /// dispatch + `ceiling`.
    struct RestoreTiming: Equatable {
        var floor: TimeInterval = 2.5
        var grace: TimeInterval = 0.2
        var ceiling: TimeInterval = 10
        static let standard = RestoreTiming()
    }

    typealias Scheduler = (TimeInterval, DispatchWorkItem) -> Void

    /// nspasteboard.org marker. Compliant clipboard managers skip items that
    /// carry it without reading them, so they don't fake an early receipt.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// `completion` runs on the main queue and reports event dispatch and
    /// clipboard disturbance. Neither confirms insertion into the target app.
    /// `onReadyForNext` releases queue ownership after a read or resolution,
    /// independently of later restoration, or after typing/failure completes.
    static func inject(
        _ text: String,
        pasteboard: any InjectionClipboard = NSPasteboard.general,
        target: CommandTarget? = nil,
        validateTarget: @MainActor (CommandTarget) -> Bool = { validateCommandTarget($0) },
        timing: RestoreTiming = .standard,
        isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() },
        postPaste: @MainActor () -> Bool = { postKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        typeText: (@MainActor (String, @escaping (Bool) -> Void) -> Void)? = nil,
        onReadyForNext: (() -> Void)? = nil,
        onDispatch: (() -> Void)? = nil,
        completion: ((InjectionResult) -> Void)? = nil
    ) {
        let trace = DictationTrace.current
        guard !text.isEmpty else {
            completion?(.dispatchFailed)
            onReadyForNext?()
            return
        }
        if isSecureInputEnabled() {
            guard target == nil else {
                completion?(.targetChanged)
                onReadyForNext?()
                return
            }
            // Password field or similar: avoid the clipboard entirely.
            let finished: (InjectionResult) -> Void = { result in
                completion?(result)
                onReadyForNext?()
            }
            if let typeText {
                typeText(text) { posted in
                    if posted { onDispatch?() }
                    finished(posted ? .dispatched : .dispatchFailed)
                }
            } else {
                typeString(text, trace: trace, onDispatch: onDispatch, completion: finished)
            }
            return
        }

        // Two dictations can land within one restore window (recording while
        // the previous one transcribes is allowed). Keep the snapshot from
        // the FIRST of the sequence — snapshotting now would capture the
        // previous dictation as "the user's clipboard" and lose the real one.
        // Reading a previous clipboard provider may block. Validate the command
        // after that read, before changing clipboard or restoration ownership.
        let newSnapshot = savedItems == nil || pasteboard.changeCount != ourChangeCount
            ? pasteboard.snapshotItems() : nil
        if let target, !validateTarget(target) {
            completion?(.targetChanged)
            onReadyForNext?()
            return
        }
        restoreWork?.cancel()
        restoreWork = nil
        restoreGeneration &+= 1
        // A superseded injection never reaches its restore work — resolve it
        // now with the same signal the work item would have used.
        resolvePending(undisturbed: pasteboard.changeCount == ourChangeCount)
        if let newSnapshot { savedItems = newSnapshot }

        let generation = restoreGeneration
        let scheduleRestore: (TimeInterval) -> Void = { delay in
            let work = DispatchWorkItem { restore(generation, on: pasteboard) }
            restoreWork = work
            schedule(delay, work)
        }
        // Promise the text instead of writing it, so the first reader tells
        // us the paste is being serviced.
        let receipt = PasteReceipt(text: text, onRead: {
            let read = { noteRead(generation, at: now(), timing: timing, trace: trace, scheduleRestore: scheduleRestore) }
            // In-process reads call the provider synchronously and
            // out-of-process reads are serviced on the main run loop, so
            // this is main in practice. Hop if it ever isn't.
            if Thread.isMainThread {
                MainActor.assumeIsolated(read)
            } else {
                DispatchQueue.main.async(execute: read)
            }
        }, onFinish: {
            // Provider teardown may run inside our own clipboard writes.
            // Resolve external replacement on the next turn, after changeCount moves.
            DispatchQueue.main.async {
                guard generation == restoreGeneration,
                      pasteboard.changeCount != ourChangeCount else { return }
                restoreWork?.cancel()
                restoreWork = nil
                pasteReceipt = nil
                savedItems = nil
                resolvePending(undisturbed: false)
            }
        })
        pasteReceipt = receipt
        pasteboard.promise(receipt)
        ourChangeCount = pasteboard.changeCount
        guard postPaste() else {
            trace?.record(.pasteDispatched, status: .failed)
            // No Cmd-V went out — put the user's clipboard back right away.
            pasteReceipt = nil
            if let saved = savedItems {
                savedItems = nil
                pasteboard.replaceItems(saved)
            }
            completion?(.dispatchFailed)
            onReadyForNext?()
            return
        }
        trace?.record(.pasteDispatched, status: .success)
        let dispatched = now()
        dispatchedAt = dispatched
        pendingReady = onReadyForNext
        onDispatch?()
        pendingCompletion = { undisturbed, readObserved in
            trace?.record(.clipboardWindowResolved, status: undisturbed ? .unchangedClipboard : .changedClipboard, fields: [
                .readObserved: readObserved ? 1 : 0,
                .restoreDelayMs: (now() - dispatched) * 1000
            ])
            completion?(undisturbed ? .dispatched : .clipboardChanged)
        }

        // Slow apps can take well over a second to service the paste, and
        // restoring too early pastes the user's old clipboard instead of the
        // dictation. Wait for a read, or the ceiling if nothing reads.
        scheduleRestore(timing.ceiling)
    }

    /// True from Cmd+V dispatch until the target app reads the paste or the
    /// clipboard is restored. While it's true the frontmost app may be
    /// blocked waiting for our main thread to fulfil the promised string, so
    /// a synchronous Accessibility call into it would stall both apps.
    static var isAwaitingPasteboardRead: Bool {
        dispatchedAt != nil && readObservedAt == nil
    }

    /// Delay from the moment the receipt arrives until the restore.
    static func restoreDelay(sinceDispatch elapsed: TimeInterval, timing: RestoreTiming) -> TimeInterval {
        max(timing.grace, timing.floor - elapsed)
    }

    /// Restores a pending snapshot now. No-op when nothing is pending.
    /// For the quit path and tests.
    static func restoreNow() {
        guard let work = restoreWork else { return }
        work.perform()
        work.cancel()
    }

    private static func noteRead(
        _ generation: Int, at time: TimeInterval, timing: RestoreTiming,
        trace: DictationTrace?, scheduleRestore: (TimeInterval) -> Void
    ) {
        // The provider runs once per item, so only the first read counts.
        guard generation == restoreGeneration, let dispatchedAt, readObservedAt == nil else { return }
        readObservedAt = time
        let elapsed = time - dispatchedAt
        trace?.record(.pasteboardRead, fields: [.readLatencyMs: elapsed * 1000])
        restoreWork?.cancel()
        scheduleRestore(restoreDelay(sinceDispatch: elapsed, timing: timing))
        // Let the provider return its bytes before another paste replaces them.
        let ready = pendingReady
        pendingReady = nil
        DispatchQueue.main.async { ready?() }
    }

    private static func restore(_ generation: Int, on pasteboard: any InjectionClipboard) {
        guard generation == restoreGeneration else { return }
        restoreWork = nil
        pasteReceipt = nil
        let saved = savedItems
        savedItems = nil
        // changeCount moved = the user copied something themselves in
        // the meantime. Theirs wins over the restore, and whether the
        // paste landed first is unknowable.
        let undisturbed = pasteboard.changeCount == ourChangeCount
        if undisturbed, let saved {
            pasteboard.replaceItems(saved)
        }
        resolvePending(undisturbed: undisturbed)
    }

    /// Clears per-injection state before calling out, so a completion that
    /// starts the next injection sees a clean slate.
    private static func resolvePending(undisturbed: Bool) {
        guard let done = pendingCompletion else { return }
        let readObserved = readObservedAt != nil
        pendingCompletion = nil
        let ready = pendingReady
        pendingReady = nil
        dispatchedAt = nil
        readObservedAt = nil
        done(undisturbed, readObserved)
        ready?()
    }

    enum SelectionError: Error, LocalizedError, Equatable {
        case unavailable

        var errorDescription: String? {
            "The focused app doesn't expose a readable text selection. Focus an editable text field and check Flo's Accessibility permission, then try again."
        }
    }

    typealias SelectionAttributeReader = @MainActor (AXUIElement, CFString) -> (AXError, CFTypeRef?)

    private static func frontmostAccessibilityApplication() -> AXUIElement? {
        NSWorkspace.shared.frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static func selectionAttribute(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (error, value)
    }

    /// Electron builds its text accessibility tree asynchronously. Start it
    /// before recording so the focused field is available when speech returns.
    static func prepareSelectionAccess(
        focusedApplication: @MainActor () -> AXUIElement? = frontmostAccessibilityApplication,
        readAttribute: SelectionAttributeReader = selectionAttribute,
        writeAttribute: (AXUIElement, CFString, CFTypeRef) -> AXError = AXUIElementSetAttributeValue
    ) {
        guard let application = focusedApplication() else { return }
        let attribute = "AXManualAccessibility" as CFString
        let (error, enabled) = readAttribute(application, attribute)
        guard error == .success, let enabled = enabled as? Bool, !enabled else { return }
        _ = writeAttribute(application, attribute, kCFBooleanTrue)
    }

    /// Reads selection through Accessibility without touching the clipboard.
    /// An unsupported selection is an error, not a request to generate new text.
    static func copySelection(
        isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() },
        focusedApplication: @MainActor () -> AXUIElement? = frontmostAccessibilityApplication,
        readAttribute: SelectionAttributeReader = selectionAttribute,
        completion: (Result<String?, SelectionError>) -> Void
    ) {
        guard !isSecureInputEnabled() else {
            completion(.success(nil))
            return
        }
        guard let appElement = focusedApplication() else {
            completion(.failure(.unavailable))
            return
        }
        let (focusError, focus) = readAttribute(appElement, kAXFocusedUIElementAttribute as CFString)
        guard focusError == .success, let focus,
              CFGetTypeID(focus) == AXUIElementGetTypeID() else {
            completion(.failure(.unavailable))
            return
        }
        let focusedElement = focus as! AXUIElement
        completion(selectedText(in: focusedElement, readAttribute: readAttribute))
    }

    private static func selectedText(
        in element: AXUIElement, readAttribute: SelectionAttributeReader
    ) -> Result<String?, SelectionError> {
        let (error, value) = readAttribute(element, kAXSelectedTextAttribute as CFString)
        if error == .noValue { return .success(nil) }
        guard error == .success, let text = value as? String else { return .failure(.unavailable) }
        return .success(text.isEmpty ? nil : text)
    }

    /// AX application identity includes the process. Element and window identity
    /// distinguish fields and windows within that process; the range also guards a cursor.
    struct CommandTarget {
        let application: AXUIElement
        let element: AXUIElement
        let window: AXUIElement?
        let selection: String?
        let range: CFRange
    }

    private static func selectedRange(
        in element: AXUIElement, readAttribute: SelectionAttributeReader
    ) -> CFRange? {
        let (error, value) = readAttribute(element, kAXSelectedTextRangeAttribute as CFString)
        var range = CFRange()
        guard error == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    static func captureCommandTarget(
        isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() },
        focusedApplication: @MainActor () -> AXUIElement? = frontmostAccessibilityApplication,
        readAttribute: SelectionAttributeReader = selectionAttribute
    ) -> Result<CommandTarget, SelectionError> {
        guard !isAwaitingPasteboardRead, !isSecureInputEnabled(),
              let app = focusedApplication() else { return .failure(.unavailable) }
        let (focusError, focus) = readAttribute(app, kAXFocusedUIElementAttribute as CFString)
        guard focusError == .success, let focus,
              CFGetTypeID(focus) == AXUIElementGetTypeID() else { return .failure(.unavailable) }
        let element = focus as! AXUIElement
        guard let range = selectedRange(in: element, readAttribute: readAttribute) else { return .failure(.unavailable) }
        let selection: String?
        switch selectedText(in: element, readAttribute: readAttribute) {
        case .success(let text): selection = text
        case .failure(let error): return .failure(error)
        }
        // A nonempty range without readable text is not an insertion point.
        guard (range.length == 0) == (selection == nil) else { return .failure(.unavailable) }
        let (windowError, windowValue) = readAttribute(app, kAXFocusedWindowAttribute as CFString)
        let window: AXUIElement?
        if windowError == .success, let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            window = (windowValue as! AXUIElement)
        } else if windowError == .attributeUnsupported || windowError == .noValue {
            window = nil
        } else {
            return .failure(.unavailable)
        }

        // AX reads can block while another process changes focus or selection.
        // Check the selection again, then close with live window/field/app identity
        // so retained attributes from an unfocused element cannot approve a paste.
        guard let finalRange = selectedRange(in: element, readAttribute: readAttribute),
              range.location == finalRange.location, range.length == finalRange.length,
              case .success(let finalSelection) = selectedText(in: element, readAttribute: readAttribute),
              selection == finalSelection else { return .failure(.unavailable) }
        let (finalWindowError, finalWindow) = readAttribute(app, kAXFocusedWindowAttribute as CFString)
        if let window {
            guard finalWindowError == .success, let finalWindow, CFEqual(window, finalWindow) else {
                return .failure(.unavailable)
            }
        } else {
            guard finalWindowError == .attributeUnsupported || finalWindowError == .noValue else {
                return .failure(.unavailable)
            }
        }
        let (finalFocusError, finalFocus) = readAttribute(app, kAXFocusedUIElementAttribute as CFString)
        guard finalFocusError == .success, let finalFocus, CFEqual(element, finalFocus),
              let finalApp = focusedApplication(), CFEqual(app, finalApp),
              !isSecureInputEnabled() else { return .failure(.unavailable) }
        return .success(CommandTarget(application: app, element: element, window: window,
                                      selection: selection, range: range))
    }

    static func validateCommandTarget(
        _ target: CommandTarget,
        isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() },
        focusedApplication: @MainActor () -> AXUIElement? = frontmostAccessibilityApplication,
        readAttribute: SelectionAttributeReader = selectionAttribute
    ) -> Bool {
        guard case .success(let current) = captureCommandTarget(
            isSecureInputEnabled: isSecureInputEnabled,
            focusedApplication: focusedApplication, readAttribute: readAttribute
        ) else { return false }
        let sameWindow: Bool
        switch (target.window, current.window) {
        case (nil, nil): sameWindow = true
        case (.some(let original), .some(let focused)): sameWindow = CFEqual(original, focused)
        default: sameWindow = false
        }
        return CFEqual(target.application, current.application)
            && CFEqual(target.element, current.element) && sameWindow
            && target.range.location == current.range.location && target.range.length == current.range.length
            && target.selection == current.selection
    }

    // MARK: - Synthesized events

    private static func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // Serial so overlapping dictations type in order, off the main thread
    // (the per-chunk sleeps would stall it; CGEvent posting is thread-safe).
    private static let typingQueue = DispatchQueue(label: "LocalFlow.TextTyping", qos: .userInitiated)

    /// Types text as synthesized unicode keyboard events, in chunks (long
    /// strings on a single event get truncated by some apps).
    /// `completion` runs on the main queue once every chunk has been posted.
    private static func typeString(_ text: String, trace: DictationTrace?, onDispatch: (() -> Void)?, completion: ((InjectionResult) -> Void)? = nil) {
        let chunks = utf16Chunks(text)
        typingQueue.async {
            trace?.record(.typingStarted)
            let source = CGEventSource(stateID: .combinedSessionState)
            var allPosted = true

            for (index, chunk) in chunks.enumerated() {
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                } else {
                    allPosted = false
                }
                if index < chunks.count - 1 { usleep(8_000) }
            }
            trace?.record(.typingDispatched, status: allPosted ? .success : .failed)
            DispatchQueue.main.async {
                if allPosted { onDispatch?() }
                completion?(allPosted ? .dispatched : .dispatchFailed)
            }
        }
    }

    /// Splits UTF-16 at scalar boundaries. A fixed-width split can put the
    /// halves of an emoji's surrogate pair on separate CGEvents and corrupt it.
    static func utf16Chunks(_ text: String, maxUnits: Int = 20) -> [[UInt16]] {
        precondition(maxUnits >= 2)
        let units = Array(text.utf16)
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxUnits, units.count)
            if end < units.count,
               (0xD800 ... 0xDBFF).contains(units[end - 1]),
               (0xDC00 ... 0xDFFF).contains(units[end]) {
                end -= 1
            }
            chunks.append(Array(units[start ..< end]))
            start = end
        }
        return chunks
    }
}

/// Supplies the dictation text on first read and reports that read. AppKit
/// calls the provider at most once per type, then serves cached bytes, so
/// the receipt is one-shot and can't tell the target app from anyone else.
final class PasteReceipt: NSObject, NSPasteboardItemDataProvider {
    private var text: String?
    private let onRead: () -> Void
    private let onFinish: () -> Void

    init(text: String, onRead: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.text = text
        self.onRead = onRead
        self.onFinish = onFinish
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let text else { return }
        // Set it on the item, not the pasteboard. Writing to the pasteboard
        // would bump changeCount and look like the user copied something.
        item.setString(text, forType: type)
        onRead()
    }

    /// Fires when the item leaves the pasteboard, including during our own
    /// clearContents(). The owner distinguishes external replacement by generation.
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        finish()
    }

    func finish() {
        text = nil
        onFinish()
    }
}

/// The clipboard boundary used by injection. Tests keep receipts and snapshots in memory.
@MainActor
protocol InjectionClipboard: AnyObject {
    var changeCount: Int { get }
    func snapshotItems() -> [NSPasteboardItem]
    func replaceItems(_ items: [NSPasteboardItem])
    func promise(_ receipt: PasteReceipt)
}

extension NSPasteboard: InjectionClipboard {
    func snapshotItems() -> [NSPasteboardItem] {
        (pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    func replaceItems(_ items: [NSPasteboardItem]) {
        clearContents()
        writeObjects(items)
    }

    func promise(_ receipt: PasteReceipt) {
        let item = NSPasteboardItem()
        if !item.setDataProvider(receipt, forTypes: [.string]) {
            receipt.pasteboard(nil, item: item, provideDataForType: .string)
        }
        item.setData(Data(), forType: TextInjector.transientType)
        replaceItems([item])
    }
}
