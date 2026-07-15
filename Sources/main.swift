import Cocoa
import Foundation
import Carbon.HIToolbox
import ServiceManagement
import IOKit

// ============================================================================
// MARK: - Logging
// ============================================================================
//
// Two levels:
//   logMsg(_:)   — always appended to ~/Library/Logs/MacGesture/MacGesture.log
//                  and mirrored to stdout when debugMode is on. Use for
//                  lifecycle / errors / config changes.
//   logDebug(_:) — only emitted when debugMode is on. Use for verbose
//                  per-touch / per-frame noise. Gating lives in the logger so
//                  call sites don't need their own `if debugMode { ... }`.
//
// The log file rotates to MacGesture.log.1 once it exceeds 1 MB — one previous
// file is kept.

enum Log {
    private static let queue = DispatchQueue(label: "com.macgesture.log")
    private static let maxBytes: UInt64 = 1_000_000

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacGesture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MacGesture.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        if debugMode { Swift.print(message) }
        appendToFile(message)
    }

    static func debug(_ message: String) {
        guard debugMode else { return }
        Swift.print(message)
        appendToFile(message)
    }

    private static func appendToFile(_ message: String) {
        let now = Date()
        queue.async {
            rotateIfNeeded()
            let line = "[\(formatter.string(from: now))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64, size >= maxBytes else { return }
        let rotated = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }
}

func logMsg(_ message: String) { Log.info(message) }
func logDebug(_ message: String) { Log.debug(message) }

// ============================================================================
// MARK: - MultitouchSupport Framework Bridge
// ============================================================================

typealias MTContactCallbackFunction = @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutableRawPointer,
    Int32,
    Double,
    Int32
) -> Void

private let mtFrameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
private let mtFramework: UnsafeMutableRawPointer? = dlopen(mtFrameworkPath, RTLD_LAZY)

private let _MTDeviceCreateList: @convention(c) () -> CFArray = {
    guard let handle = mtFramework, let sym = dlsym(handle, "MTDeviceCreateList") else {
        fatalError("Cannot load MTDeviceCreateList")
    }
    return unsafeBitCast(sym, to: (@convention(c) () -> CFArray).self)
}()

private let _MTDeviceStart: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32 = {
    guard let handle = mtFramework, let sym = dlsym(handle, "MTDeviceStart") else {
        fatalError("Cannot load MTDeviceStart")
    }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self)
}()

private let _MTDeviceStop: @convention(c) (UnsafeMutableRawPointer) -> Void = {
    guard let handle = mtFramework, let sym = dlsym(handle, "MTDeviceStop") else {
        fatalError("Cannot load MTDeviceStop")
    }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
}()

private let _MTRegisterContactFrameCallback: @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFunction) -> Void = {
    guard let handle = mtFramework, let sym = dlsym(handle, "MTRegisterContactFrameCallback") else {
        fatalError("Cannot load MTRegisterContactFrameCallback")
    }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer, MTContactCallbackFunction) -> Void).self)
}()

private let _MTUnregisterContactFrameCallback: @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFunction) -> Void = {
    guard let handle = mtFramework, let sym = dlsym(handle, "MTUnregisterContactFrameCallback") else {
        fatalError("Cannot load MTUnregisterContactFrameCallback")
    }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer, MTContactCallbackFunction) -> Void).self)
}()

// ============================================================================
// MARK: - MultitouchSupport Touch Types
// ============================================================================
//
// Layout reverse-engineered from Apple's private MultitouchSupport.framework.
// Source: github.com/asmagill/hs._asm.undocumented.touchdevice
// Total struct size is 96 bytes on current macOS (verified at startup).

struct MTPoint {
    var x: Float
    var y: Float
}

struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

enum MTPathStage: Int32 {
    case notTracking   = 0
    case startInRange  = 1
    case hoverInRange  = 2
    case makeTouch     = 3
    case touching      = 4
    case breakTouch    = 5
    case lingerInRange = 6
    case outOfRange    = 7
}

struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var stage: Int32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var zPressure: Float
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

// ============================================================================
// MARK: - Palm Rejection
// ============================================================================
//
// The framework reports every contact, including palms. NSTouch (the public
// API) filters palms in the driver but is window-scoped and useless for a
// system-wide listener. We do the filter ourselves with three rules,
// derived from logged trackpad data:
//
//   1. Large ellipse (majorAxis > palmMajorAxisThreshold) → classic full palm.
//   2. Elongated ellipse (eccentricity = majorAxis / minorAxis > threshold)
//      → palm-shaped contact regardless of position. Real fingertips are
//      nearly circular (eccentricity ≤ ~1.5); palm-edge contacts run 1.85+.
//   3. Top/bottom edge + low capacitance density → resting palm or thumb
//      along the edge of the trackpad. Finger-sized ellipse but light,
//      diffuse contact (zDensity < 1.0); real fingertips run 1.0–1.5.
//
// Left/right edges are intentionally not flagged — real fingers commonly
// land there. All thresholds are observable via the per-touch debug log.

enum PalmFilter {
    static let majorAxisThreshold: Float = 12.0           // rule 1: large palm
    static let eccentricityThreshold: Float = 1.85        // rule 2: elongated palm ellipse
    static let minMajorForEccentricityRule: Float = 7.0   // rule 2: gate to avoid noisy small touches
    static let edgeY: Float = 0.10                        // rule 3: top/bottom edge band
    static let edgeDensityMax: Float = 1.0                // rule 3: low density threshold at edge
}

var palmRejectionEnabled = true

extension MTTouch {
    var eccentricity: Float {
        guard minorAxis > 0.01 else { return 0 }
        return majorAxis / minorAxis
    }

    var isAtTopOrBottomEdge: Bool {
        let y = normalizedVector.position.y
        return y < PalmFilter.edgeY || y > 1 - PalmFilter.edgeY
    }

    var isLikelyPalm: Bool {
        guard palmRejectionEnabled else { return false }
        if majorAxis > PalmFilter.majorAxisThreshold { return true }
        if majorAxis > PalmFilter.minMajorForEccentricityRule
           && eccentricity > PalmFilter.eccentricityThreshold { return true }
        if isAtTopOrBottomEdge && zDensity < PalmFilter.edgeDensityMax { return true }
        return false
    }

    /// One-line diagnostic used in debug logging when tuning palm rejection.
    var diagnosticLine: String {
        let px = String(format: "%.2f", normalizedVector.position.x)
        let py = String(format: "%.2f", normalizedVector.position.y)
        let maj = String(format: "%.1f", majorAxis)
        let min = String(format: "%.1f", minorAxis)
        let zT = String(format: "%.2f", zTotal)
        let zD = String(format: "%.2f", zDensity)
        let zP = String(format: "%.2f", zPressure)
        let kind = isLikelyPalm ? "PALM" : "finger"
        return "  • pos(\(px),\(py)) maj=\(maj) min=\(min) zTot=\(zT) zDen=\(zD) zP=\(zP) stage=\(stage) [\(kind)]"
    }
}

// ============================================================================
// MARK: - TouchFrame
// ============================================================================
//
// Snapshot of one multitouch callback — raw touches converted to typed values,
// palm-filtered, with the aggregates the recognizer needs.

struct TouchFrame {
    let fingers: [MTTouch]           // palm-filtered (kept)
    let rejectedTouches: [MTTouch]   // filtered out as palms — kept for diagnostics
    let timestamp: TimeInterval

    init(rawTouches: UnsafeBufferPointer<MTTouch>, timestamp: TimeInterval) {
        var fs: [MTTouch] = []
        var rs: [MTTouch] = []
        fs.reserveCapacity(rawTouches.count)
        for t in rawTouches {
            if t.isLikelyPalm { rs.append(t) } else { fs.append(t) }
        }
        self.fingers = fs
        self.rejectedTouches = rs
        self.timestamp = timestamp
    }

    var fingerCount: Int { fingers.count }
    var rejectedPalms: Int { rejectedTouches.count }
    var allTouches: [MTTouch] { fingers + rejectedTouches }

    var centroid: MTPoint? {
        guard !fingers.isEmpty else { return nil }
        var sx: Float = 0, sy: Float = 0
        for f in fingers {
            sx += f.normalizedVector.position.x
            sy += f.normalizedVector.position.y
        }
        return MTPoint(x: sx / Float(fingers.count), y: sy / Float(fingers.count))
    }
}

// ============================================================================
// MARK: - Gesture Events
// ============================================================================
//
// The recognizer emits high-level events. Today there's only .tap; .swipe and
// .hold can slot in here when Tier 2/3 lands without changing recognizer shape.

enum GestureEvent {
    case tap(fingers: Int)
}

// ============================================================================
// MARK: - Gesture Recognizer
// ============================================================================
//
// Stateful per-frame classifier. Same tap logic the app has always had:
//   • 3+ fingers land → start tracking
//   • More fingers added → upgrade peak, reset baseline
//   • Movement tracked only at peak count (lifting fingers shifts the centroid,
//     which would otherwise look like a swipe and reject the tap)
//   • Peak drops → evaluate: duration in band AND movement small → emit tap

final class GestureRecognizer {
    var onEvent: (GestureEvent) -> Void = { _ in }

    private var trackingStart: TimeInterval = 0
    private var peakFingers: Int = 0
    private var startCentroid: MTPoint?
    private var maxDeviation: Float = 0

    private var isTracking: Bool { peakFingers > 0 }

    func process(_ frame: TouchFrame) {
        let count = frame.fingerCount

        if count >= 3 && !isTracking {
            beginTracking(frame: frame, fingers: count)
            if debugMode {
                let pos = frame.centroid.map { "(\(String(format: "%.3f", $0.x)), \(String(format: "%.3f", $0.y)))" } ?? "n/a"
                let palmNote = frame.rejectedPalms > 0 ? " [palm-filtered \(frame.rejectedPalms)]" : ""
                logDebug("👆 \(count)-finger touch started at \(pos)\(palmNote)")
                for t in frame.allTouches { logDebug(t.diagnosticLine) }
            }
        }

        if count >= 3 && isTracking {
            if count > peakFingers {
                beginTracking(frame: frame, fingers: count)
                logDebug("👆 Upgraded to \(count)-finger gesture")
                if debugMode {
                    for t in frame.allTouches { logDebug(t.diagnosticLine) }
                }
            } else if count == peakFingers {
                updateDeviation(frame: frame)
            }
        }

        if isTracking && count < peakFingers {
            evaluate(at: frame.timestamp)
            reset()
        }

        if count == 0 {
            reset()
        }
    }

    private func beginTracking(frame: TouchFrame, fingers: Int) {
        trackingStart = frame.timestamp
        peakFingers = fingers
        startCentroid = frame.centroid
        maxDeviation = 0
    }

    private func updateDeviation(frame: TouchFrame) {
        guard let start = startCentroid, let current = frame.centroid else { return }
        let dx = current.x - start.x
        let dy = current.y - start.y
        let dist = sqrtf(dx * dx + dy * dy)
        if dist > maxDeviation { maxDeviation = dist }
    }

    private func evaluate(at timestamp: TimeInterval) {
        let duration = timestamp - trackingStart
        let validDuration = duration > minTapDuration && duration < tapThreshold
        let validMovement = maxDeviation < maxMovement

        if debugMode {
            let ms = String(format: "%.0f", duration * 1000)
            let mv = String(format: "%.4f", maxDeviation)
            if validDuration && validMovement {
                logDebug("✅ \(peakFingers)-FINGER TAP candidate (\(ms)ms, moved \(mv))")
            } else if peakFingers >= 3 && peakFingers <= 5 {
                let reasons = [
                    validDuration ? nil : "duration(\(ms)ms)",
                    validMovement ? nil : "movement(\(mv))",
                ].compactMap { $0 }
                logDebug("❌ Rejected \(peakFingers)F: \(reasons.joined(separator: ", "))")
            }
        }

        guard validDuration && validMovement else { return }
        onEvent(.tap(fingers: peakFingers))
    }

    private func reset() {
        peakFingers = 0
        startCentroid = nil
        maxDeviation = 0
    }
}

let gestureRecognizer = GestureRecognizer()

// ============================================================================
// MARK: - Action Definitions
// ============================================================================

enum TapAction: String, CaseIterable {
    case none             = "none"
    case middleClick      = "middle_click"
    case rightClick       = "right_click"
    case closeTab         = "close_tab"
    case newTab           = "new_tab"
    case reopenTab        = "reopen_tab"
    case refreshPage      = "refresh_page"
    case copySelection    = "copy"
    case pasteClipboard   = "paste"
    case undo             = "undo"
    case missionControl   = "mission_control"
    case launchpad        = "launchpad"
    case spotlight        = "spotlight"
    case customShortcut   = "custom_shortcut"

    var displayName: String {
        switch self {
        case .none:           return "Disabled"
        case .middleClick:    return "Middle Click"
        case .rightClick:     return "Right Click"
        case .closeTab:       return "Close Tab  (⌘W)"
        case .newTab:         return "New Tab  (⌘T)"
        case .reopenTab:      return "Reopen Closed Tab  (⇧⌘T)"
        case .refreshPage:    return "Refresh Page  (⌘R)"
        case .copySelection:  return "Copy  (⌘C)"
        case .pasteClipboard: return "Paste  (⌘V)"
        case .undo:           return "Undo  (⌘Z)"
        case .missionControl: return "Mission Control"
        case .launchpad:      return "Launchpad"
        case .spotlight:      return "Spotlight  (⌘Space)"
        case .customShortcut: return "Custom Shortcut"
        }
    }

    var category: String {
        switch self {
        case .none: return "Off"
        case .middleClick, .rightClick: return "Mouse"
        case .closeTab, .newTab, .reopenTab, .refreshPage: return "Browser"
        case .copySelection, .pasteClipboard, .undo: return "Edit"
        case .missionControl, .launchpad, .spotlight: return "System"
        case .customShortcut: return "Custom"
        }
    }

    var isEnabled: Bool { return self != .none }

    func execute() {
        guard self != .none else { return }
        switch self {
        case .none:             break
        case .middleClick:      simulateMiddleClick()
        case .rightClick:       simulateRightClick()
        case .closeTab:         simulateKeyCombo(key: kVK_ANSI_W, flags: .maskCommand)
        case .newTab:           simulateKeyCombo(key: kVK_ANSI_T, flags: .maskCommand)
        case .reopenTab:        simulateKeyCombo(key: kVK_ANSI_T, flags: [.maskCommand, .maskShift])
        case .refreshPage:      simulateKeyCombo(key: kVK_ANSI_R, flags: .maskCommand)
        case .copySelection:    simulateKeyCombo(key: kVK_ANSI_C, flags: .maskCommand)
        case .pasteClipboard:   simulateKeyCombo(key: kVK_ANSI_V, flags: .maskCommand)
        case .undo:             simulateKeyCombo(key: kVK_ANSI_Z, flags: .maskCommand)
        case .missionControl:   openMissionControl()
        case .launchpad:        openLaunchpad()
        case .spotlight:        simulateKeyCombo(key: kVK_Space, flags: .maskCommand)
        case .customShortcut:   break // handled separately with finger count context
        }
    }
}

// ── Custom Shortcut Storage ──

struct CustomShortcut {
    var keyCode: Int
    var modifiers: UInt64 // CGEventFlags.rawValue

    var isEmpty: Bool { return keyCode == -1 }

    func execute() {
        guard !isEmpty else { return }
        simulateKeyCombo(key: keyCode, flags: CGEventFlags(rawValue: modifiers))
    }

    var displayString: String {
        guard !isEmpty else { return "Not set" }
        return formatShortcut(keyCode: keyCode, modifiers: CGEventFlags(rawValue: modifiers))
    }
}

var customShortcut3 = CustomShortcut(keyCode: -1, modifiers: 0)
var customShortcut4 = CustomShortcut(keyCode: -1, modifiers: 0)
var customShortcut5 = CustomShortcut(keyCode: -1, modifiers: 0)

func customShortcutFor(fingerCount: Int) -> CustomShortcut {
    switch fingerCount {
    case 3: return customShortcut3
    case 4: return customShortcut4
    case 5: return customShortcut5
    default: return CustomShortcut(keyCode: -1, modifiers: 0)
    }
}

func executeGestureAction(action: TapAction, fingerCount: Int) {
    if action == .customShortcut {
        customShortcutFor(fingerCount: fingerCount).execute()
    } else {
        action.execute()
    }
}

func formatShortcut(keyCode: Int, modifiers: CGEventFlags) -> String {
    var parts: [String] = []
    if modifiers.contains(.maskControl)   { parts.append("⌃") }
    if modifiers.contains(.maskAlternate) { parts.append("⌥") }
    if modifiers.contains(.maskShift)     { parts.append("⇧") }
    if modifiers.contains(.maskCommand)   { parts.append("⌘") }

    let keyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
    ]

    parts.append(keyNames[keyCode] ?? "Key\(keyCode)")
    return parts.joined()
}

let selectableActions = TapAction.allCases.filter { $0 != .none && $0 != .customShortcut }

// ============================================================================
// MARK: - Action Execution Helpers
// ============================================================================

enum EventSim {
    /// Delay between paired down/up CGEvents. Below ~10ms some targets miss
    /// the down event entirely; 15ms is the smallest value that's been
    /// reliable across browsers / Mission Control / shortcut recipients.
    static let downUpDelayUs: useconds_t = 15_000
}

func simulateMiddleClick() {
    guard let sourceEvent = CGEvent(source: nil) else { return }
    let cgPoint = sourceEvent.location
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                              mouseCursorPosition: cgPoint, mouseButton: .center),
          let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                            mouseCursorPosition: cgPoint, mouseButton: .center) else { return }
    down.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    up.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    down.post(tap: .cghidEventTap)
    usleep(EventSim.downUpDelayUs)
    up.post(tap: .cghidEventTap)
    logDebug("🖱️ Middle-click at (\(Int(cgPoint.x)), \(Int(cgPoint.y)))")
}

func simulateRightClick() {
    guard let sourceEvent = CGEvent(source: nil) else { return }
    let cgPoint = sourceEvent.location
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                              mouseCursorPosition: cgPoint, mouseButton: .right),
          let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                            mouseCursorPosition: cgPoint, mouseButton: .right) else { return }
    down.post(tap: .cghidEventTap)
    usleep(EventSim.downUpDelayUs)
    up.post(tap: .cghidEventTap)
    logDebug("🖱️ Right-click at (\(Int(cgPoint.x)), \(Int(cgPoint.y)))")
}

func simulateKeyCombo(key: Int, flags: CGEventFlags) {
    guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false) else { return }
    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    usleep(EventSim.downUpDelayUs)
    keyUp.post(tap: .cghidEventTap)
    logDebug("⌨️ Key combo executed")
}

func openMissionControl() {
    // Key code 160 = Mission Control (F3/Exposé key), same approach as Launchpad.
    // Falls back to launching Mission Control.app if the key event doesn't work.
    if let kd = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(160), keyDown: true),
       let ku = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(160), keyDown: false) {
        kd.post(tap: .cghidEventTap); usleep(EventSim.downUpDelayUs); ku.post(tap: .cghidEventTap)
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    }
}

func openLaunchpad() {
    if let kd = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(160), keyDown: true),
       let ku = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(160), keyDown: false) {
        kd.post(tap: .cghidEventTap); usleep(EventSim.downUpDelayUs); ku.post(tap: .cghidEventTap)
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
    }
}

// ============================================================================
// MARK: - Gesture Configuration
// ============================================================================

struct GestureConfig {
    let fingerCount: Int
    var action: TapAction
    var label: String { return "\(fingerCount)-Finger Tap" }
    var prefKey: String { return "action_\(fingerCount)finger" }
}

var gesture3 = GestureConfig(fingerCount: 3, action: .middleClick)
var gesture4 = GestureConfig(fingerCount: 4, action: .none)
var gesture5 = GestureConfig(fingerCount: 5, action: .none)

func gestureConfig(for fingerCount: Int) -> GestureConfig? {
    switch fingerCount {
    case 3: return gesture3
    case 4: return gesture4
    case 5: return gesture5
    default: return nil
    }
}

// ============================================================================
// MARK: - Global State
// ============================================================================

var isEnabled = true
var debugMode = false
var tapThreshold: TimeInterval = 0.12
let minTapDuration: TimeInterval = 0.02
var maxMovement: Float = 0.03

var registeredDevices: [UnsafeMutableRawPointer] = []

let defaults = UserDefaults.standard
let kSensitivity = "tapThreshold"
let kEnabled = "isEnabled"
let kMaxMovement = "maxMovement"
let kDebugMode = "debugMode"
let kPalmRejection = "palmRejectionEnabled"

func loadPreferences() {
    if let s = defaults.string(forKey: gesture3.prefKey), let a = TapAction(rawValue: s) { gesture3.action = a }
    if let s = defaults.string(forKey: gesture4.prefKey), let a = TapAction(rawValue: s) { gesture4.action = a }
    if let s = defaults.string(forKey: gesture5.prefKey), let a = TapAction(rawValue: s) { gesture5.action = a }
    if defaults.object(forKey: kSensitivity) != nil { tapThreshold = defaults.double(forKey: kSensitivity) }
    if defaults.object(forKey: kEnabled) != nil { isEnabled = defaults.bool(forKey: kEnabled) }
    if defaults.object(forKey: kMaxMovement) != nil { maxMovement = Float(defaults.double(forKey: kMaxMovement)) }
    if defaults.object(forKey: kDebugMode) != nil { debugMode = defaults.bool(forKey: kDebugMode) }
    if defaults.object(forKey: kPalmRejection) != nil { palmRejectionEnabled = defaults.bool(forKey: kPalmRejection) }

    // Load custom shortcuts
    for fc in [3, 4, 5] {
        let keyVal = defaults.object(forKey: "custom_key_\(fc)finger") as? Int ?? -1
        let modVal = defaults.object(forKey: "custom_mod_\(fc)finger") as? UInt64 ?? 0
        let cs = CustomShortcut(keyCode: keyVal, modifiers: modVal)
        switch fc {
        case 3: customShortcut3 = cs
        case 4: customShortcut4 = cs
        case 5: customShortcut5 = cs
        default: break
        }
    }

    // Migrate old single-action preference
    if let old = defaults.string(forKey: "selectedAction"), let a = TapAction(rawValue: old) {
        gesture4.action = a
        defaults.removeObject(forKey: "selectedAction")
        savePreferences()
    }
}

func savePreferences() {
    defaults.set(gesture3.action.rawValue, forKey: gesture3.prefKey)
    defaults.set(gesture4.action.rawValue, forKey: gesture4.prefKey)
    defaults.set(gesture5.action.rawValue, forKey: gesture5.prefKey)
    defaults.set(tapThreshold, forKey: kSensitivity)
    defaults.set(isEnabled, forKey: kEnabled)
    defaults.set(Double(maxMovement), forKey: kMaxMovement)
    defaults.set(debugMode, forKey: kDebugMode)
    defaults.set(palmRejectionEnabled, forKey: kPalmRejection)

    // Save custom shortcuts
    for fc in [3, 4, 5] {
        let cs = customShortcutFor(fingerCount: fc)
        defaults.set(cs.keyCode, forKey: "custom_key_\(fc)finger")
        defaults.set(cs.modifiers, forKey: "custom_mod_\(fc)finger")
    }
}

// ============================================================================
// MARK: - Multitouch Callback
// ============================================================================
//
// Thin shim: bind the raw pointer to MTTouch, build a TouchFrame, hand it to
// the recognizer. All logic lives in GestureRecognizer / TouchFrame.

let touchCallback: MTContactCallbackFunction = { _, touchData, numTouches, timestamp, _ in
    guard isEnabled, numTouches >= 0 else { return }
    let typed = touchData.bindMemory(to: MTTouch.self, capacity: Int(numTouches))
    let buffer = UnsafeBufferPointer(start: typed, count: Int(numTouches))
    let frame = TouchFrame(rawTouches: buffer, timestamp: timestamp)
    gestureRecognizer.process(frame)
}

func installGestureDispatcher() {
    gestureRecognizer.onEvent = { event in
        switch event {
        case .tap(let fingers):
            guard let config = gestureConfig(for: fingers), config.action.isEnabled else { return }
            let action = config.action
            logDebug("🎯 \(fingers)-finger tap → \(action.displayName)")
            DispatchQueue.main.async { executeGestureAction(action: action, fingerCount: fingers) }
        }
    }
}

// ============================================================================
// MARK: - Device Management
// ============================================================================

func startMultitouchMonitoring() {
    logDebug("🔧 MTTouch struct stride: \(MemoryLayout<MTTouch>.stride) bytes (expected 96)")
    let cfList = _MTDeviceCreateList()
    let count = CFArrayGetCount(cfList)
    if count == 0 { logMsg("❌ No multitouch devices found"); return }

    registeredDevices.removeAll()
    for i in 0..<count {
        guard let rawPtr = CFArrayGetValueAtIndex(cfList, i) else { continue }
        let device = UnsafeMutableRawPointer(mutating: rawPtr)
        _MTRegisterContactFrameCallback(device, touchCallback)
        if _MTDeviceStart(device, 0) == 0 {
            registeredDevices.append(device)
            logMsg("✅ Device \(i): started")
        }
    }
    logMsg("📱 Monitoring \(registeredDevices.count)/\(count) device(s)")
}

func restartMonitoring() {
    // Tear down old handles before re-enumerating. Without this, each restart
    // leaks an AppleMultitouchDeviceUserClient in kernel space; ~100 leaks
    // accumulated over a day eventually break frame delivery for all devices.
    for d in registeredDevices {
        _MTUnregisterContactFrameCallback(d, touchCallback)
        _MTDeviceStop(d)
    }
    registeredDevices.removeAll()
    startMultitouchMonitoring()
}

// ============================================================================
// MARK: - Menu Bar Icon
// ============================================================================

func createMenuBarIcon(enabled: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        let ctx = NSGraphicsContext.current!.cgContext
        let color: NSColor = enabled ? .labelColor : .tertiaryLabelColor
        ctx.setFillColor(color.cgColor)

        let dotR: CGFloat = 1.6
        let y: CGFloat = 12.0
        let dotCount = 4
        let totalWidth: CGFloat = 14.0
        let spacing = totalWidth / CGFloat(dotCount - 1)
        let startX: CGFloat = 2.0
        for i in 0..<dotCount {
            ctx.fillEllipse(in: CGRect(x: startX + CGFloat(i) * spacing - dotR,
                                        y: y, width: dotR * 2, height: dotR * 2))
        }

        let padRect = CGRect(x: 1.5, y: 1.0, width: 15, height: 9)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.2)
        let path = CGPath(roundedRect: padRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(path)
        ctx.strokePath()

        return true
    }
    image.isTemplate = true
    return image
}

// ============================================================================
// MARK: - Accessibility Helper
// ============================================================================

/// Check accessibility WITHOUT prompting (for UI status display)
func isAccessibilityGranted() -> Bool {
    return AXIsProcessTrusted()
}

/// Check accessibility WITH prompt (for first launch)
func checkAccessibilityWithPrompt() -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

// ============================================================================
// MARK: - External Links
// ============================================================================

private let kBuyMeACoffeeURL = "https://www.buymeacoffee.com/is.harshul"

// ============================================================================
// MARK: - Login Item Management
// ============================================================================

func setupLoginItem() {
    if #available(macOS 13.0, *) {
        let service = SMAppService.mainApp
        let status = service.status
        
        switch status {
        case .notRegistered:
            do {
                try service.register()
                logMsg("✅ Login item registered successfully")
            } catch {
                logMsg("⚠️  Failed to register login item: \(error.localizedDescription)")
            }
        case .enabled:
            logMsg("✅ Login item already enabled")
        case .requiresApproval:
            logMsg("⚠️  Login item requires user approval in System Settings")
        case .notFound:
            logMsg("❌ Login item service not found")
        @unknown default:
            logMsg("⚠️  Unknown login item status")
        }
    } else {
        logMsg("⚠️  Login item management requires macOS 13.0+")
    }
}

func isLoginItemEnabled() -> Bool {
    if #available(macOS 13.0, *) {
        return SMAppService.mainApp.status == .enabled
    }
    return false
}

func setLoginItem(_ enabled: Bool) {
    if #available(macOS 13.0, *) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    logMsg("✅ Login item enabled")
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                    logMsg("✅ Login item disabled")
                }
            }
        } catch {
            logMsg("❌ Failed to toggle login item: \(error.localizedDescription)")
        }
    }
}

// ============================================================================
// MARK: - Popover Content ViewController
// ============================================================================

class GesturePopoverVC: NSViewController {
    let W: CGFloat = 300
    let padH: CGFloat = 12 // horizontal padding (left & right)
    let padVTop: CGFloat = 4 // padding above header
    let padVBottom: CGFloat = 8 // padding below footer
    var tabControl: NSSegmentedControl!
    var actionContainer: NSView!
    var actionButtons: [NSButton] = []
    var selectedTab = 0  // 0=3F, 1=4F, 2=5F — default to 3F (primary default gesture)
    var shortcutRecorderBtn: NSButton?
    var keyMonitor: Any?
    var isRecording = false

    weak var appDelegate: AppDelegate?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 100))
        view.wantsLayer = true
        rebuildUI()
    }

    func rebuildUI() {
        view.subviews.forEach { $0.removeFromSuperview() }
        actionButtons.removeAll()

        // Reset view frame to prevent stale geometry from previous popover showing
        view.frame = NSRect(x: 0, y: 0, width: W, height: 100)

        let innerW = W - padH * 2
        var y: CGFloat = padVBottom

        // ── BUY ME A COFFEE ──
        let coffeeBtn = makeLink("☕ Buy me a coffee", action: #selector(openBuyMeACoffee))
        coffeeBtn.target = self
        coffeeBtn.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(coffeeBtn)
        y += 22

        // ── QUIT + VERSION ──
        let quitBtn = makeLink("Quit MacGesture", action: #selector(appDelegate?.doQuit), color: NSColor(red: 227/255.0, green: 34/255.0, blue: 39/255.0, alpha: 1.0))
        quitBtn.target = appDelegate
        quitBtn.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(quitBtn)

        let versionStr = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.1"
        let vLabel = NSTextField(labelWithString: "v\(versionStr)")
        vLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        vLabel.textColor = .tertiaryLabelColor
        vLabel.sizeToFit()
        vLabel.frame.origin = CGPoint(x: W - padH - vLabel.frame.width, y: y + 1)
        view.addSubview(vLabel)
        y += 24

        sep(&y)

        // ── TOOLS ──
        let debugBtn = makeCheckbox("Debug Logging", checked: debugMode, action: #selector(appDelegate?.toggleDebug))
        debugBtn.target = appDelegate
        debugBtn.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(debugBtn)
        y += 22

        let palmBtn = makeCheckbox("Palm Rejection", checked: palmRejectionEnabled, action: #selector(appDelegate?.togglePalmRejection))
        palmBtn.target = appDelegate
        palmBtn.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(palmBtn)
        y += 22
        
        // Open at Login toggle (macOS 13.0+)
        if #available(macOS 13.0, *) {
            let loginBtn = makeCheckbox("Open at Login", checked: isLoginItemEnabled(), action: #selector(appDelegate?.toggleLoginItem))
            loginBtn.target = appDelegate
            loginBtn.frame.origin = CGPoint(x: padH, y: y)
            view.addSubview(loginBtn)
            y += 22
        }

        let restartBtn = makeLink("Restart Touch Detection", action: #selector(appDelegate?.doRestart))
        restartBtn.target = appDelegate
        restartBtn.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(restartBtn)
        y += 22

        let testBtn = makeLink("Test Current Tab Action (2s)", action: #selector(doTest))
        testBtn.target = self
        testBtn.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(testBtn)
        y += 24

        sep(&y)

        // ── GENERAL SETTINGS ──
        sectionHeader("GENERAL", at: &y)

        // Movement tolerance
        label("Movement Tolerance", at: &y)
        let movPopup = NSPopUpButton(frame: NSRect(x: padH, y: y, width: innerW, height: 24), pullsDown: false)
        movPopup.font = .systemFont(ofSize: 11); movPopup.controlSize = .small
        let tolerances: [(String, Float)] = [
            ("Strict (1.5mm)", 0.015), ("Default (3mm)", 0.03),
            ("Loose (5mm)", 0.05), ("Very Loose (8mm)", 0.08), ("Disabled", 1.0)
        ]
        for (i, (lbl, val)) in tolerances.enumerated() {
            movPopup.addItem(withTitle: lbl)
            movPopup.item(at: i)?.representedObject = val
            if abs(val - maxMovement) < 0.001 { movPopup.selectItem(at: i) }
        }
        movPopup.target = appDelegate; movPopup.action = #selector(appDelegate?.movementChanged(_:))
        view.addSubview(movPopup)
        y += 28

        // Tap duration
        label("Tap Duration (max)", at: &y)
        let durPopup = NSPopUpButton(frame: NSRect(x: padH, y: y, width: innerW, height: 24), pullsDown: false)
        durPopup.font = .systemFont(ofSize: 11); durPopup.controlSize = .small
        let durations: [(String, TimeInterval)] = [
            ("80ms (very fast)", 0.08), ("100ms (fast)", 0.10),
            ("120ms (default)", 0.12), ("150ms (comfortable)", 0.15),
            ("200ms (relaxed)", 0.20), ("250ms (generous)", 0.25),
            ("350ms (very generous)", 0.35)
        ]
        for (i, (lbl, val)) in durations.enumerated() {
            durPopup.addItem(withTitle: lbl)
            durPopup.item(at: i)?.representedObject = val
            if abs(val - tapThreshold) < 0.001 { durPopup.selectItem(at: i) }
        }
        durPopup.target = appDelegate; durPopup.action = #selector(appDelegate?.durationChanged(_:))
        view.addSubview(durPopup)
        y += 28

        sep(&y)

        // ── ACTION LIST (for selected tab) ──
        actionContainer = NSView(frame: NSRect(x: 0, y: y, width: W, height: 0))
        view.addSubview(actionContainer)
        buildActionList()
        y += actionContainer.frame.height

        sep(&y)

        // ── TAB CONTROL ──
        tabControl = NSSegmentedControl(labels: ["3F", "4F", "5F"], trackingMode: .selectOne,
                                         target: self, action: #selector(tabChanged))
        tabControl.selectedSegment = selectedTab
        tabControl.segmentStyle = .texturedRounded
        tabControl.frame = NSRect(x: padH, y: y, width: innerW, height: 26)
        let segmentWidth = innerW / 3
        for i in 0..<3 { tabControl.setWidth(segmentWidth, forSegment: i) }
        view.addSubview(tabControl)
        updateTabAppearance()
        y += 30

        sep(&y)

        // ── ENABLED TOGGLE ──
        let enableBtn = makeCheckbox("Enabled", checked: isEnabled, action: #selector(appDelegate?.toggleEnabled))
        enableBtn.target = appDelegate
        enableBtn.font = .systemFont(ofSize: 12, weight: .medium)
        enableBtn.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(enableBtn)
        y += 24

        sep(&y)

        // ── ACCESSIBILITY STATUS ──
        let granted = isAccessibilityGranted()
        let accessBg = NSView(frame: NSRect(x: padH, y: y, width: innerW, height: 28))
        accessBg.wantsLayer = true
        accessBg.layer?.cornerRadius = 6
        let softGreen = NSColor(red: 0.53, green: 0.92, blue: 0.45, alpha: 0.95)
        let softAmber = NSColor(red: 0.72, green: 0.62, blue: 0.20, alpha: 0.95)
        accessBg.layer?.backgroundColor = granted
            ? softGreen.withAlphaComponent(0.1).cgColor
            : softAmber.withAlphaComponent(0.1).cgColor
        view.addSubview(accessBg)

        let dotColor: NSColor = granted ? softGreen : softAmber
        let dotLabel = NSTextField(labelWithString: "●")
        dotLabel.font = .systemFont(ofSize: 10)
        dotLabel.textColor = dotColor
        dotLabel.sizeToFit()
        dotLabel.frame.origin = CGPoint(x: padH + 8, y: y + 7)
        view.addSubview(dotLabel)

        let statusText = granted ? "Accessibility: Granted" : "Accessibility: Not Granted"
        let statusLabel = NSTextField(labelWithString: statusText)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = granted ? softGreen : softAmber
        statusLabel.sizeToFit()
        statusLabel.frame.origin = CGPoint(x: padH + 22, y: y + 6)
        view.addSubview(statusLabel)

        if !granted {
            let grantBtn = makeLink("Grant →", action: #selector(openAccessSettings), color: softAmber)
            grantBtn.target = self
            grantBtn.font = .systemFont(ofSize: 11, weight: .medium)
            grantBtn.sizeToFit()
            grantBtn.frame.origin = CGPoint(x: W - padH - grantBtn.frame.width - 6, y: y + 5)
            view.addSubview(grantBtn)
        }
        y += 30

        // ── HEADER ──
        let header = NSTextField(labelWithString: "MacGesture")
        header.font = .boldSystemFont(ofSize: 15)
        header.textColor = .labelColor
        header.sizeToFit()
        header.frame.origin = CGPoint(x: padH, y: y - 4)
        view.addSubview(header)

        let summaryText = gesturesSummaryShort()
        let summary = NSTextField(labelWithString: summaryText)
        summary.font = .systemFont(ofSize: 9)
        summary.textColor = .tertiaryLabelColor
        summary.sizeToFit()
        summary.frame.origin = CGPoint(x: W - padH - summary.frame.width, y: y + 2)
        view.addSubview(summary)
        y += 22 + padVTop

        // Final — set both the view frame and preferredContentSize so the
        // popover sizes correctly on every open, not just the first time.
        let finalSize = NSSize(width: W, height: y)
        view.frame = NSRect(origin: .zero, size: finalSize)
        preferredContentSize = finalSize
    }

    func buildActionList() {
        actionContainer.subviews.forEach { $0.removeFromSuperview() }
        actionButtons.removeAll()
        stopRecording()

        let gesture = currentGesture()
        var y: CGFloat = 4

        // Disabled option
        let offBtn = makeRadio("Disabled (Off)", selected: gesture.action == .none, tag: -1)
        offBtn.frame.origin = CGPoint(x: padH + 4, y: y)
        actionContainer.addSubview(offBtn)
        actionButtons.append(offBtn)
        y += 20

        for category in ["Mouse", "Browser", "Edit", "System"] {
            let actions = selectableActions.filter { $0.category == category }
            if actions.isEmpty { continue }

            let catLabel = NSTextField(labelWithString: category.uppercased())
            catLabel.font = .systemFont(ofSize: 9, weight: .semibold)
            catLabel.textColor = .tertiaryLabelColor
            catLabel.sizeToFit()
            catLabel.frame.origin = CGPoint(x: padH + 4, y: y + 2)
            actionContainer.addSubview(catLabel)
            y += 16

            for act in actions {
                let tag = TapAction.allCases.firstIndex(of: act) ?? 0
                let btn = makeRadio(act.displayName, selected: act == gesture.action, tag: tag)
                btn.frame.origin = CGPoint(x: padH + 16, y: y)
                actionContainer.addSubview(btn)
                actionButtons.append(btn)
                y += 20
            }
            y += 2
        }

        // ── CUSTOM SHORTCUT ──
        let customCatLabel = NSTextField(labelWithString: "CUSTOM")
        customCatLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        customCatLabel.textColor = .tertiaryLabelColor
        customCatLabel.sizeToFit()
        customCatLabel.frame.origin = CGPoint(x: padH + 4, y: y + 2)
        actionContainer.addSubview(customCatLabel)
        y += 16

        let customTag = TapAction.allCases.firstIndex(of: .customShortcut) ?? 0
        let customBtn = makeRadio("Custom Keyboard Shortcut", selected: gesture.action == .customShortcut, tag: customTag)
        customBtn.frame.origin = CGPoint(x: padH + 16, y: y)
        actionContainer.addSubview(customBtn)
        actionButtons.append(customBtn)
        y += 22

        // Shortcut recorder button
        let cs = customShortcutFor(fingerCount: gesture.fingerCount)
        let recorderTitle = cs.isEmpty ? "Click to record shortcut..." : cs.displayString
        let recorder = NSButton(title: recorderTitle, target: self, action: #selector(startRecordingShortcut))
        recorder.bezelStyle = .recessed
        recorder.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        recorder.frame = NSRect(x: padH + 28, y: y, width: W - padH * 2 - 28, height: 26)
        recorder.isEnabled = (gesture.action == .customShortcut)
        recorder.alphaValue = (gesture.action == .customShortcut) ? 1.0 : 0.4
        actionContainer.addSubview(recorder)
        shortcutRecorderBtn = recorder
        y += 28

        y += 4
        actionContainer.frame.size.height = y
    }

    func currentGesture() -> GestureConfig {
        switch selectedTab {
        case 0: return gesture3
        case 2: return gesture5
        default: return gesture4
        }
    }

    func updateTabAppearance() {
        let gestures = [gesture3, gesture4, gesture5]
        for (i, g) in gestures.enumerated() {
            let label = "\(g.fingerCount)F" + (g.action.isEnabled ? " ●" : "")
            tabControl.setLabel(label, forSegment: i)
        }
    }

    func gesturesSummaryShort() -> String {
        var parts: [String] = []
        if gesture3.action.isEnabled { parts.append("3F") }
        if gesture4.action.isEnabled { parts.append("4F") }
        if gesture5.action.isEnabled { parts.append("5F") }
        return parts.isEmpty ? "none active" : parts.joined(separator: " · ") + " active"
    }

    // MARK: - Actions

    @objc func tabChanged() {
        selectedTab = tabControl.selectedSegment
        // Only rebuild action list and tab labels — avoids full UI rebuild and layout shift
        buildActionList()
        updateTabAppearance()
    }

    @objc func actionSelected(_ sender: NSButton) {
        let tag = sender.tag
        let action: TapAction
        if tag == -1 {
            action = .none
        } else {
            let allCases = TapAction.allCases
            guard tag >= 0 && tag < allCases.count else { return }
            action = allCases[tag]
        }

        switch selectedTab {
        case 0: gesture3.action = action
        case 2: gesture5.action = action
        default: gesture4.action = action
        }

        savePreferences()
        appDelegate?.updateIcon()
        logMsg("🔧 \(currentGesture().fingerCount)-finger → \(action.displayName)")

        let gesture = currentGesture()
        for btn in actionButtons {
            if btn.tag == -1 {
                btn.state = gesture.action == .none ? .on : .off
            } else {
                let allCases = TapAction.allCases
                if btn.tag < allCases.count {
                    btn.state = allCases[btn.tag] == gesture.action ? .on : .off
                }
            }
        }

        // Enable/disable shortcut recorder based on selection
        let isCustom = (action == .customShortcut)
        shortcutRecorderBtn?.isEnabled = isCustom
        shortcutRecorderBtn?.alphaValue = isCustom ? 1.0 : 0.4
        if !isCustom { stopRecording() }

        updateTabAppearance()
    }

    @objc func startRecordingShortcut() {
        guard !isRecording else { return }
        isRecording = true
        shortcutRecorderBtn?.title = "Press a key combo..."
        shortcutRecorderBtn?.contentTintColor = .systemOrange

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            let keyCode = Int(event.keyCode)
            // Convert NSEvent modifier flags to CGEventFlags
            var cgFlags: UInt64 = 0
            if event.modifierFlags.contains(.command)  { cgFlags |= CGEventFlags.maskCommand.rawValue }
            if event.modifierFlags.contains(.shift)    { cgFlags |= CGEventFlags.maskShift.rawValue }
            if event.modifierFlags.contains(.option)   { cgFlags |= CGEventFlags.maskAlternate.rawValue }
            if event.modifierFlags.contains(.control)  { cgFlags |= CGEventFlags.maskControl.rawValue }

            let cs = CustomShortcut(keyCode: keyCode, modifiers: cgFlags)
            let fingerCount = self.currentGesture().fingerCount
            switch fingerCount {
            case 3: customShortcut3 = cs
            case 4: customShortcut4 = cs
            case 5: customShortcut5 = cs
            default: break
            }
            savePreferences()

            self.shortcutRecorderBtn?.title = cs.displayString
            self.shortcutRecorderBtn?.contentTintColor = nil
            self.stopRecording()
            logMsg("🔧 Custom shortcut for \(fingerCount)F → \(cs.displayString)")
            return nil // consume the event
        }
    }

    func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        isRecording = false
    }

    @objc func doTest() {
        let gesture = currentGesture()
        let action = gesture.action
        guard action.isEnabled else {
            logMsg("🧪 No action configured for \(gesture.fingerCount)-finger tap")
            return
        }
        let fingerCount = gesture.fingerCount
        let displayName = action == .customShortcut
            ? customShortcutFor(fingerCount: fingerCount).displayString
            : action.displayName
        logMsg("🧪 Testing '\(displayName)' in 2s...")
        appDelegate?.popover.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            executeGestureAction(action: action, fingerCount: fingerCount)
            logMsg("🧪 Done!")
        }
    }

    @objc func openAccessSettings() {
        openAccessibilitySettings()
    }

    @objc func openBuyMeACoffee() {
        guard let url = URL(string: kBuyMeACoffeeURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - UI Helpers

    func makeRadio(_ title: String, selected: Bool, tag: Int) -> NSButton {
        let btn = NSButton(radioButtonWithTitle: title, target: self, action: #selector(actionSelected(_:)))
        btn.font = .systemFont(ofSize: 11)
        btn.state = selected ? .on : .off
        btn.tag = tag
        btn.sizeToFit()
        return btn
    }

    func makeCheckbox(_ title: String, checked: Bool, action: Selector) -> NSButton {
        let btn = NSButton(checkboxWithTitle: title, target: nil, action: action)
        btn.font = .systemFont(ofSize: 12)
        btn.state = checked ? .on : .off
        btn.sizeToFit()
        return btn
    }

    func makeLink(_ title: String, action: Selector, color: NSColor = .systemBlue) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: action)
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 11)
        btn.contentTintColor = color
        btn.sizeToFit()
        return btn
    }

    func sep(_ y: inout CGFloat) {
        let s = NSBox(frame: NSRect(x: padH, y: y, width: W - padH * 2, height: 1))
        s.boxType = .separator
        view.addSubview(s)
        y += 8
    }

    func sectionHeader(_ text: String, at y: inout CGFloat) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        l.sizeToFit()
        l.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(l)
        y += 16
    }

    func label(_ text: String, at y: inout CGFloat) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.sizeToFit()
        l.frame.origin = CGPoint(x: padH, y: y)
        view.addSubview(l)
        y += 16
    }
}

// ============================================================================
// MARK: - AppDelegate
// ============================================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    var popoverVC: GesturePopoverVC!
    var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        logMsg("========================================")
        logMsg("  MacGesture v3.1")
        logMsg("========================================")

        loadPreferences()
        
        // Enable login item by default (macOS 13.0+)
        setupLoginItem()

        // Check accessibility (with prompt on first launch)
        let granted = checkAccessibilityWithPrompt()
        logMsg(granted ? "✅ Accessibility: GRANTED" : "⚠️  Accessibility: NOT YET GRANTED")
        if !granted {
            let a = NSAlert()
            a.messageText = "Accessibility Permission Required"
            a.informativeText = "MacGesture needs Accessibility permission to detect trackpad gestures and simulate actions.\n\nAfter every rebuild, you may need to toggle the permission OFF and ON again in System Settings.\n\nSystem Settings → Privacy & Security → Accessibility"
            a.alertStyle = .warning
            a.addButton(withTitle: "Open System Settings")
            a.addButton(withTitle: "Continue")
            if a.runModal() == .alertFirstButtonReturn {
                openAccessibilitySettings()
            }
        }

        setupStatusBar()
        installGestureDispatcher()
        startMultitouchMonitoring()

        // Periodic accessibility re-check (every 5s) — auto-restart monitoring when granted
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            let nowGranted = isAccessibilityGranted()
            if nowGranted && registeredDevices.isEmpty {
                logMsg("✅ Accessibility just granted — starting touch monitoring")
                startMultitouchMonitoring()
            }
        }

        // Watch for AppleMultitouchDevice appearances. The held MTDevice handle goes
        // stale when the underlying IOService is destroyed and recreated — happens on
        // lid-close (internal trackpad SPI re-enumerates) and on Bluetooth trackpad
        // power-cycle. kIOFirstMatchNotification fires after the new IOService has
        // started; re-enumerate via restartMonitoring to pick up the fresh handle.
        let notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort!).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        let onMatched: IOServiceMatchingCallback = { _, iter in
            var count = 0
            var svc = IOIteratorNext(iter)
            while svc != 0 {
                count += 1
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
            logMsg("🔌 \(count) multitouch device(s) appeared — restarting monitoring")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                restartMonitoring()
            }
        }

        var addedIter: io_iterator_t = 0
        IOServiceAddMatchingNotification(notifyPort, kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"), onMatched, nil, &addedIter)

        // Drain the initial iterator to arm the notification. The pre-existing devices
        // are already registered via startMultitouchMonitoring() above, so we discard
        // them here without invoking the callback (no restart needed at launch).
        var initialSvc = IOIteratorNext(addedIter)
        while initialSvc != 0 {
            IOObjectRelease(initialSvc)
            initialSvc = IOIteratorNext(addedIter)
        }

        logMsg("")
        logMsg("🚀 Running!")
        for (g, fc) in [(gesture3, 3), (gesture4, 4), (gesture5, 5)] {
            let name = g.action == .customShortcut
                ? "\(g.action.displayName) (\(customShortcutFor(fingerCount: fc).displayString))"
                : g.action.displayName
            logMsg("   \(fc)-finger: \(name)")
        }
        logMsg("   Tap window:   \(Int(tapThreshold * 1000))ms")
        logMsg("   Max movement: \(String(format: "%.2f", maxMovement))")
        logMsg("========================================")
    }

    // MARK: - Status Bar

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        popoverVC = GesturePopoverVC()
        popoverVC.appDelegate = self
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    func updateIcon() {
        statusItem.button?.image = createMenuBarIcon(enabled: isEnabled)
        if isEnabled {
            var active: [String] = []
            for (g, fc) in [(gesture3, 3), (gesture4, 4), (gesture5, 5)] {
                guard g.action.isEnabled else { continue }
                let name = g.action == .customShortcut
                    ? customShortcutFor(fingerCount: fc).displayString
                    : g.action.displayName
                active.append("\(fc)F→\(name)")
            }
            statusItem.button?.toolTip = active.isEmpty
                ? "MacGesture — No gestures configured"
                : "MacGesture — \(active.joined(separator: ", "))"
        } else {
            statusItem.button?.toolTip = "MacGesture — Disabled"
        }
    }

    // MARK: - Popover

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Rebuild UI first, then assign a fresh VC so the popover
            // picks up the new preferredContentSize cleanly every time.
            popoverVC = GesturePopoverVC()
            popoverVC.appDelegate = self
            popover.contentViewController = popoverVC
            popover.contentSize = popoverVC.preferredContentSize
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                // Activate the app so the popover's window becomes key,
                // which allows .transient behavior to dismiss on outside click.
                NSApp.activate(ignoringOtherApps: true)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    // MARK: - Actions from Popover

    @objc func toggleEnabled(_ sender: NSButton) {
        isEnabled = (sender.state == .on)
        updateIcon()
        savePreferences()
    }

    @objc func toggleDebug(_ sender: NSButton) {
        debugMode = (sender.state == .on)
        savePreferences()
        logMsg(debugMode ? "🔍 Debug ON — tap the trackpad to see events" : "🔍 Debug OFF")
    }

    @objc func togglePalmRejection(_ sender: NSButton) {
        palmRejectionEnabled = (sender.state == .on)
        savePreferences()
        logMsg(palmRejectionEnabled ? "✋ Palm rejection ON" : "✋ Palm rejection OFF")
    }
    
    @objc func toggleLoginItem(_ sender: NSButton) {
        let enabled = (sender.state == .on)
        setLoginItem(enabled)
    }

    @objc func durationChanged(_ sender: NSPopUpButton) {
        guard let val = sender.selectedItem?.representedObject as? TimeInterval else { return }
        tapThreshold = val
        savePreferences()
        logMsg("⏱️ Tap duration → \(Int(val * 1000))ms")
    }

    @objc func movementChanged(_ sender: NSPopUpButton) {
        guard let val = sender.selectedItem?.representedObject as? Float else { return }
        maxMovement = val
        savePreferences()
        logMsg("📏 Movement tolerance → \(String(format: "%.1f", val * 100))mm")
    }

    @objc func doRestart() {
        popover.performClose(nil)
        restartMonitoring()
    }

    @objc func doQuit() {
        NSApplication.shared.terminate(nil)
    }
}

// ============================================================================
// MARK: - Entry Point
// ============================================================================

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
