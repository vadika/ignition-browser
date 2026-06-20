import AppKit
import Carbon.HIToolbox

/// The owner holds the HotKey for as long as the shortcut should be live; deinit unregisters.
/// The static map stores only the handler closure (keyed by Carbon id) so the context-free C
/// callback can route to it — it does not retain the HotKey.
/// ponytail: handles a single hotkey per instance; that's all the app needs.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private let id: UInt32

    @MainActor private static var handlers: [UInt32: () -> Void] = [:]
    @MainActor private static var nextID: UInt32 = 1

    /// keyCode = Carbon virtual keycode (e.g. kVK_ANSI_I = 34).
    /// modifiers = Carbon mask (e.g. UInt32(optionKey | cmdKey)).
    @MainActor
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.id = HotKey.nextID
        HotKey.nextID += 1

        // ponytail: installs one app-target handler per instance. Fine for the single
        // app-lifetime hotkey this app creates; if multiple HotKeys are ever needed, install
        // the kEventHotKeyPressed handler once into a static instead (it dispatches by id).
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), HotKey.callback, 1, &spec, nil, &handlerRef)
        guard installStatus == noErr else { return nil }

        let hkID = EventHotKeyID(signature: OSType(0x49474E54), id: id) // 'IGNT'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        HotKey.handlers[id] = handler
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        let id = self.id
        DispatchQueue.main.async { @MainActor in HotKey.handlers[id] = nil }
    }

    private static let callback: EventHandlerUPP = { _, event, _ in
        var hkID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        let id = hkID.id
        DispatchQueue.main.async { @MainActor in HotKey.handlers[id]?() }
        return noErr
    }
}
