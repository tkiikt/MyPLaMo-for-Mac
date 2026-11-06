import AppKit
import Carbon
import ApplicationServices

@MainActor final class DesktopIntegration {
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var action: (() -> Void)?
    func register(keyCode: UInt32 = 17, modifiers: UInt32 = UInt32(cmdKey | optionKey)) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let instance = Unmanaged<DesktopIntegration>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in instance.action?() }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        return RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x4C54524E, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
    func disable() { if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil } }
    func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return nil }
        var value: CFTypeRef?
        let element = focused as! AXUIElement
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func insert(_ text: String, into app: NSRunningApplication) async -> Bool {
        guard AXIsProcessTrusted(), !app.isTerminated else { return false }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in item.data(forType: type).map { (type, $0) } }
        } ?? []
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount
        app.activate()
        try? await Task.sleep(for: .milliseconds(250))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
            return false
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(600))
        if pasteboard.changeCount == changeCount {
            pasteboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        return true
    }
}
