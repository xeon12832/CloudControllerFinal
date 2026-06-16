import SwiftUI
import AppKit
import Network
import Combine
import ApplicationServices

class AppControllerServer: ObservableObject {
    @Published var connectionStatus = "Server offline"
    @Published var permissionStatus = "Checking keyboard access..."
    @Published var activeInput = "No input"
    @Published var controllerState = ControllerState()
    @Published var bindings = KeyBinding.defaults
    @Published var remappingControl: ControllerControl?
    
    private let port: NWEndpoint.Port = 8026
    private var listener: NWListener?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var heldKeyCodes = Set<UInt16>()
    
    init() {
        refreshPermissionStatus()
        startLocalServer()
        startGlobalKeyboardTracking()
    }
    
    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        
        listener?.cancel()
    }
    
    func requestKeyboardAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        
        for urlString in settingsURLs {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                break
            }
        }
        
        refreshPermissionStatus()
    }
    
    func startRemapping(_ control: ControllerControl) {
        remappingControl = control
        activeInput = "Press a key for \(control.title)"
    }
    
    func resetBindings() {
        bindings = KeyBinding.defaults
        remappingControl = nil
        heldKeyCodes.removeAll()
        updateControllerState()
    }
    
    private func startLocalServer() {
        do {
            listener = try NWListener(using: .tcp, on: port)
            
            listener?.stateUpdateHandler = { state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.connectionStatus = "Bridge active on localhost:\(self.port.rawValue)"
                    case .failed(let error):
                        self.connectionStatus = "Bridge error: \(error.localizedDescription)"
                    case .waiting(let error):
                        self.connectionStatus = "Waiting: \(error.localizedDescription)"
                    case .cancelled:
                        self.connectionStatus = "Bridge stopped"
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }
            
            listener?.start(queue: .main)
        } catch {
            connectionStatus = "Could not start bridge"
        }
    }
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, _ in
            guard let self = self else { return }
            
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let wantsScript = request.contains("GET /script")
            let wantsJSON = request.contains("GET /state") || request.contains("GET /json")
            let payloadString = wantsScript
                ? BrowserBridgeScript.chromeDevToolsCode
                : (wantsJSON ? self.controllerState.jsonPayload : self.controllerState.legacyPayload)
            let contentType = wantsScript
                ? "application/javascript"
                : (wantsJSON ? "application/json" : "text/plain")
            let httpResponse = self.httpResponse(body: payloadString, contentType: contentType)
            
            if let responseData = httpResponse.data(using: .utf8) {
                connection.send(content: responseData, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
        }
    }
    
    private func startGlobalKeyboardTracking() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.processKeyEvent(event)
        }
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.processKeyEvent(event)
            return event
        }
    }
    
    private func processKeyEvent(_ event: NSEvent) {
        DispatchQueue.main.async {
            if event.type == .keyDown, let remappingControl = self.remappingControl {
                self.bindings.removeAll { $0.control == remappingControl }
                self.bindings.append(
                    KeyBinding(
                        control: remappingControl,
                        keyCode: event.keyCode,
                        keyName: KeyName.label(for: event)
                    )
                )
                self.bindings.sort { $0.control.sortOrder < $1.control.sortOrder }
                self.remappingControl = nil
                self.heldKeyCodes.removeAll()
                self.updateControllerState()
                return
            }
            
            guard self.bindings.contains(where: { $0.keyCode == event.keyCode }) else { return }
            
            if event.type == .keyDown {
                self.heldKeyCodes.insert(event.keyCode)
            } else {
                self.heldKeyCodes.remove(event.keyCode)
            }
            
            self.updateControllerState()
            self.refreshPermissionStatus()
        }
    }
    
    private func updateControllerState() {
        controllerState = ControllerState(keyCodes: heldKeyCodes, bindings: bindings)
        
        if let remappingControl {
            activeInput = "Press a key for \(remappingControl.title)"
        } else {
            activeInput = controllerState.activeInputs.isEmpty
                ? "No input"
                : controllerState.activeInputs.joined(separator: " + ")
        }
    }
    
    private func refreshPermissionStatus() {
        permissionStatus = AXIsProcessTrusted()
            ? "Keyboard access allowed"
            : "Needs Accessibility permission"
    }
    
    private func httpResponse(body: String, contentType: String) -> String {
        """
        HTTP/1.1 200 OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, OPTIONS\r
        Access-Control-Allow-Headers: *\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        \(body)
        """
    }
}

enum ControllerControl: String, CaseIterable, Identifiable {
    case leftStickUp
    case leftStickLeft
    case leftStickDown
    case leftStickRight
    case rightStickUp
    case rightStickLeft
    case rightStickDown
    case rightStickRight
    case dPadUp
    case dPadLeft
    case dPadDown
    case dPadRight
    case aButton
    case bButton
    case xButton
    case yButton
    case leftBumper
    case rightBumper
    case leftTrigger
    case rightTrigger
    case viewButton
    case menuButton
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .leftStickUp: return "Left stick up"
        case .leftStickLeft: return "Left stick left"
        case .leftStickDown: return "Left stick down"
        case .leftStickRight: return "Left stick right"
        case .rightStickUp: return "Right stick up"
        case .rightStickLeft: return "Right stick left"
        case .rightStickDown: return "Right stick down"
        case .rightStickRight: return "Right stick right"
        case .dPadUp: return "D-pad up"
        case .dPadLeft: return "D-pad left"
        case .dPadDown: return "D-pad down"
        case .dPadRight: return "D-pad right"
        case .aButton: return "A button"
        case .bButton: return "B button"
        case .xButton: return "X button"
        case .yButton: return "Y button"
        case .leftBumper: return "Left bumper"
        case .rightBumper: return "Right bumper"
        case .leftTrigger: return "Left trigger"
        case .rightTrigger: return "Right trigger"
        case .viewButton: return "View button"
        case .menuButton: return "Menu button"
        }
    }
    
    var iconName: String {
        switch self {
        case .leftStickUp: return "arrow.up.circle.fill"
        case .leftStickLeft: return "arrow.left.circle.fill"
        case .leftStickDown: return "arrow.down.circle.fill"
        case .leftStickRight: return "arrow.right.circle.fill"
        case .rightStickUp: return "arrow.up.circle"
        case .rightStickLeft: return "arrow.left.circle"
        case .rightStickDown: return "arrow.down.circle"
        case .rightStickRight: return "arrow.right.circle"
        case .dPadUp: return "dpad.up.filled"
        case .dPadLeft: return "dpad.left.filled"
        case .dPadDown: return "dpad.down.filled"
        case .dPadRight: return "dpad.right.filled"
        case .aButton: return "a.circle.fill"
        case .bButton: return "b.circle.fill"
        case .xButton: return "x.circle.fill"
        case .yButton: return "y.circle.fill"
        case .leftBumper: return "l1.button.roundedbottom.horizontal.fill"
        case .rightBumper: return "r1.button.roundedbottom.horizontal.fill"
        case .leftTrigger: return "l2.button.roundedtop.horizontal.fill"
        case .rightTrigger: return "r2.button.roundedtop.horizontal.fill"
        case .viewButton: return "rectangle.grid.2x2.fill"
        case .menuButton: return "line.3.horizontal"
        }
    }
    
    var sortOrder: Int {
        ControllerControl.allCases.firstIndex(of: self) ?? 0
    }
}

struct KeyBinding: Identifiable, Equatable {
    var id: String { control.rawValue }
    var control: ControllerControl
    var keyCode: UInt16
    var keyName: String
    
    static let defaults: [KeyBinding] = [
        KeyBinding(control: .leftStickUp, keyCode: 13, keyName: "W"),
        KeyBinding(control: .leftStickLeft, keyCode: 0, keyName: "A"),
        KeyBinding(control: .leftStickDown, keyCode: 1, keyName: "S"),
        KeyBinding(control: .leftStickRight, keyCode: 2, keyName: "D"),
        KeyBinding(control: .rightStickUp, keyCode: 126, keyName: "Up"),
        KeyBinding(control: .rightStickLeft, keyCode: 123, keyName: "Left"),
        KeyBinding(control: .rightStickDown, keyCode: 125, keyName: "Down"),
        KeyBinding(control: .rightStickRight, keyCode: 124, keyName: "Right"),
        KeyBinding(control: .dPadUp, keyCode: 34, keyName: "I"),
        KeyBinding(control: .dPadLeft, keyCode: 38, keyName: "J"),
        KeyBinding(control: .dPadDown, keyCode: 40, keyName: "K"),
        KeyBinding(control: .dPadRight, keyCode: 37, keyName: "L"),
        KeyBinding(control: .aButton, keyCode: 49, keyName: "Space"),
        KeyBinding(control: .bButton, keyCode: 11, keyName: "B"),
        KeyBinding(control: .xButton, keyCode: 7, keyName: "X"),
        KeyBinding(control: .yButton, keyCode: 16, keyName: "Y"),
        KeyBinding(control: .leftBumper, keyCode: 12, keyName: "Q"),
        KeyBinding(control: .rightBumper, keyCode: 14, keyName: "E"),
        KeyBinding(control: .leftTrigger, keyCode: 56, keyName: "Shift"),
        KeyBinding(control: .rightTrigger, keyCode: 15, keyName: "R"),
        KeyBinding(control: .viewButton, keyCode: 53, keyName: "Esc"),
        KeyBinding(control: .menuButton, keyCode: 36, keyName: "Return")
    ]
}

enum KeyName {
    static func label(for event: NSEvent) -> String {
        if let specialKey = specialKeys[event.keyCode] {
            return specialKey
        }
        
        let text = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return text.isEmpty ? "Key \(event.keyCode)" : text
    }
    
    private static let specialKeys: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Esc",
        56: "Shift",
        57: "Caps",
        58: "Option",
        59: "Control",
        123: "Left",
        124: "Right",
        125: "Down",
        126: "Up"
    ]
}

enum BrowserBridgeScript {
    static let chromeDevToolsCode = #"""
(() => {
  const LOCAL_STATE_URL = "http://localhost:8026/state";

  const gamepad = {
    id: "CloudController Keyboard Bridge",
    index: 0,
    connected: true,
    timestamp: performance.now(),
    mapping: "standard",
    axes: [0, 0, 0, 0],
    buttons: Array.from({ length: 17 }, () => ({
      pressed: false,
      touched: false,
      value: 0
    }))
  };

  function setButton(index, value) {
    const pressed = value > 0;
    gamepad.buttons[index] = { pressed, touched: pressed, value };
  }

  async function updateController() {
    try {
      const res = await fetch(LOCAL_STATE_URL, { cache: "no-store" });
      const state = await res.json();

      gamepad.timestamp = performance.now();
      gamepad.axes[0] = state.leftStick.x;
      gamepad.axes[1] = -state.leftStick.y;
      gamepad.axes[2] = state.rightStick.x;
      gamepad.axes[3] = -state.rightStick.y;

      setButton(0, state.buttons.a);
      setButton(1, state.buttons.b);
      setButton(2, state.buttons.x);
      setButton(3, state.buttons.y);
      setButton(4, state.buttons.lb);
      setButton(5, state.buttons.rb);
      setButton(6, state.triggers.left);
      setButton(7, state.triggers.right);
      setButton(8, state.buttons.view);
      setButton(9, state.buttons.menu);
      setButton(12, state.dpad.up);
      setButton(13, state.dpad.down);
      setButton(14, state.dpad.left);
      setButton(15, state.dpad.right);
    } catch (err) {
      console.warn("CloudController could not reach localhost:8026", err);
    }
  }

  const pads = [gamepad, null, null, null];

  Object.defineProperty(navigator, "getGamepads", {
    value: () => pads,
    configurable: true
  });

  Object.defineProperty(Navigator.prototype, "getGamepads", {
    value: () => pads,
    configurable: true
  });

  const event = new Event("gamepadconnected");
  Object.defineProperty(event, "gamepad", {
    value: gamepad,
    configurable: true
  });
  window.dispatchEvent(event);

  clearInterval(window.cloudControllerInterval);
  window.cloudControllerInterval = setInterval(updateController, 16);

  console.log("CloudController connected. Keep this tab open.");
})();
"""#
}

struct ControllerState {
    var leftX = 0
    var leftY = 0
    var rightX = 0
    var rightY = 0
    var leftTrigger = 0
    var rightTrigger = 0
    var a = 0
    var b = 0
    var x = 0
    var y = 0
    var lb = 0
    var rb = 0
    var menu = 0
    var view = 0
    var dPadUp = 0
    var dPadDown = 0
    var dPadLeft = 0
    var dPadRight = 0
    var activeInputs: [String] = []
    
    init() {}
    
    init(keyCodes: Set<UInt16>, bindings: [KeyBinding]) {
        leftX = axis(
            negative: Self.isPressed(.leftStickLeft, keyCodes: keyCodes, bindings: bindings),
            positive: Self.isPressed(.leftStickRight, keyCodes: keyCodes, bindings: bindings)
        )
        leftY = axis(
            negative: Self.isPressed(.leftStickDown, keyCodes: keyCodes, bindings: bindings),
            positive: Self.isPressed(.leftStickUp, keyCodes: keyCodes, bindings: bindings)
        )
        rightX = axis(
            negative: Self.isPressed(.rightStickLeft, keyCodes: keyCodes, bindings: bindings),
            positive: Self.isPressed(.rightStickRight, keyCodes: keyCodes, bindings: bindings)
        )
        rightY = axis(
            negative: Self.isPressed(.rightStickDown, keyCodes: keyCodes, bindings: bindings),
            positive: Self.isPressed(.rightStickUp, keyCodes: keyCodes, bindings: bindings)
        )
        leftTrigger = Self.isPressed(.leftTrigger, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        rightTrigger = Self.isPressed(.rightTrigger, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        a = Self.isPressed(.aButton, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        b = Self.isPressed(.bButton, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        x = Self.isPressed(.xButton, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        y = Self.isPressed(.yButton, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        lb = Self.isPressed(.leftBumper, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        rb = Self.isPressed(.rightBumper, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        view = Self.isPressed(.viewButton, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        menu = Self.isPressed(.menuButton, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        dPadUp = Self.isPressed(.dPadUp, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        dPadDown = Self.isPressed(.dPadDown, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        dPadLeft = Self.isPressed(.dPadLeft, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        dPadRight = Self.isPressed(.dPadRight, keyCodes: keyCodes, bindings: bindings) ? 1 : 0
        activeInputs = bindings
            .filter { keyCodes.contains($0.keyCode) }
            .map { "\($0.keyName) -> \($0.control.title)" }
    }
    
    var legacyPayload: String {
        let w = leftY == 1 ? 1 : 0
        let left = leftX == -1 ? 1 : 0
        let s = leftY == -1 ? 1 : 0
        let right = leftX == 1 ? 1 : 0
        return "\(w),\(left),\(s),\(right),\(a)"
    }
    
    var jsonPayload: String {
        let object: [String: Any] = [
            "leftStick": ["x": leftX, "y": leftY],
            "rightStick": ["x": rightX, "y": rightY],
            "triggers": ["left": leftTrigger, "right": rightTrigger],
            "dpad": [
                "up": dPadUp,
                "down": dPadDown,
                "left": dPadLeft,
                "right": dPadRight
            ],
            "buttons": [
                "a": a,
                "b": b,
                "x": x,
                "y": y,
                "lb": lb,
                "rb": rb,
                "menu": menu,
                "view": view
            ],
            "activeInputs": activeInputs
        ]
        
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        
        return json
    }
    
    private func axis(negative: Bool, positive: Bool) -> Int {
        switch (negative, positive) {
        case (true, false): return -1
        case (false, true): return 1
        default: return 0
        }
    }
    
    private static func isPressed(_ control: ControllerControl, keyCodes: Set<UInt16>, bindings: [KeyBinding]) -> Bool {
        bindings.contains { $0.control == control && keyCodes.contains($0.keyCode) }
    }
}

enum ThemePreset: String, CaseIterable, Identifiable {
    case navy
    case graphite
    case cobalt
    
    var id: String { rawValue }
    
    var name: String {
        switch self {
        case .navy: return "Navy"
        case .graphite: return "Graphite"
        case .cobalt: return "Cobalt"
        }
    }
    
    var theme: AppTheme {
        switch self {
        case .navy:
            return AppTheme(
                id: rawValue,
                name: name,
                background: Color(red: 0.035, green: 0.070, blue: 0.125),
                panel: Color(red: 0.075, green: 0.120, blue: 0.190),
                raisedPanel: Color(red: 0.105, green: 0.165, blue: 0.255),
                text: Color(red: 0.925, green: 0.955, blue: 0.990),
                mutedText: Color(red: 0.610, green: 0.690, blue: 0.800),
                accent: Color(red: 0.200, green: 0.760, blue: 0.960),
                success: Color(red: 0.340, green: 0.890, blue: 0.590),
                warning: Color(red: 1.000, green: 0.700, blue: 0.260)
            )
        case .graphite:
            return AppTheme(
                id: rawValue,
                name: name,
                background: Color(red: 0.075, green: 0.080, blue: 0.090),
                panel: Color(red: 0.125, green: 0.130, blue: 0.145),
                raisedPanel: Color(red: 0.170, green: 0.175, blue: 0.195),
                text: Color(red: 0.925, green: 0.955, blue: 0.990),
                mutedText: Color(red: 0.610, green: 0.690, blue: 0.800),
                accent: Color(red: 0.200, green: 0.760, blue: 0.960),
                success: Color(red: 0.340, green: 0.890, blue: 0.590),
                warning: Color(red: 1.000, green: 0.700, blue: 0.260)
            )
        case .cobalt:
            return AppTheme(
                id: rawValue,
                name: name,
                background: Color(red: 0.025, green: 0.055, blue: 0.150),
                panel: Color(red: 0.060, green: 0.105, blue: 0.245),
                raisedPanel: Color(red: 0.080, green: 0.145, blue: 0.330),
                text: Color(red: 0.925, green: 0.955, blue: 0.990),
                mutedText: Color(red: 0.610, green: 0.690, blue: 0.800),
                accent: Color(red: 0.200, green: 0.760, blue: 0.960),
                success: Color(red: 0.340, green: 0.890, blue: 0.590),
                warning: Color(red: 1.000, green: 0.700, blue: 0.260)
            )
        }
    }
}

struct AppTheme: Identifiable {
    let id: String
    let name: String
    let background: Color
    let panel: Color
    let raisedPanel: Color
    let text: Color
    let mutedText: Color
    let accent: Color
    let success: Color
    let warning: Color
    
    var accentSoft: Color { accent.opacity(0.18) }
    var border: Color { Color.white.opacity(0.16) }
    
    static func custom(base: Color, accent: Color) -> AppTheme {
        AppTheme(
            id: "custom",
            name: "Custom",
            background: base.adjusted(brightness: -0.18, saturation: 0.14),
            panel: base.adjusted(brightness: 0.02, saturation: 0.05),
            raisedPanel: base.adjusted(brightness: 0.16, saturation: 0.02),
            text: .white.opacity(0.94),
            mutedText: .white.opacity(0.64),
            accent: accent,
            success: Color(red: 0.340, green: 0.890, blue: 0.590),
            warning: Color(red: 1.000, green: 0.700, blue: 0.260)
        )
    }
}

extension Color {
    func adjusted(brightness: CGFloat, saturation: CGFloat = 0) -> Color {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .black
        var hue: CGFloat = 0
        var currentSaturation: CGFloat = 0
        var currentBrightness: CGFloat = 0
        var alpha: CGFloat = 0
        
        nsColor.getHue(
            &hue,
            saturation: &currentSaturation,
            brightness: &currentBrightness,
            alpha: &alpha
        )
        
        return Color(
            hue: Double(hue),
            saturation: Double((currentSaturation + saturation).clamped(to: 0...1)),
            brightness: Double((currentBrightness + brightness).clamped(to: 0...1)),
            opacity: Double(alpha)
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

struct ContentView: View {
    @StateObject private var server = AppControllerServer()
    @State private var showingSetupGuide = false
    @State private var showingThemeMaker = false
    @State private var selectedPreset: ThemePreset = .navy
    @State private var useCustomTheme = false
    @State private var customBaseColor = Color(red: 0.070, green: 0.120, blue: 0.200)
    @State private var customAccentColor = Color(red: 0.200, green: 0.760, blue: 0.960)
    
    private var theme: AppTheme {
        useCustomTheme ? AppTheme.custom(base: customBaseColor, accent: customAccentColor) : selectedPreset.theme
    }
    
    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
            
            HStack(alignment: .top, spacing: 34) {
                ControllerPreviewView(state: server.controllerState, theme: theme)
                    .frame(width: 430)
                
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CloudController")
                                .font(.title2)
                                .bold()
                                .foregroundStyle(theme.text)
                            Text(server.connectionStatus)
                                .font(.caption)
                                .foregroundStyle(theme.mutedText)
                        }
                        
                        Spacer()
                        
                        themeCustomizer
                        
                        Button {
                            showingSetupGuide = true
                        } label: {
                            Label("Setup", systemImage: "doc.on.clipboard")
                        }
                        .tint(theme.accent)
                        .popover(isPresented: $showingSetupGuide, arrowEdge: .top) {
                            SetupGuideView(theme: theme)
                        }
                        
                        statusPill
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Live input")
                            .font(.caption)
                            .foregroundStyle(theme.mutedText)
                        Text(server.activeInput)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.accent)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                    
                    HStack(spacing: 18) {
                        stickPreview(
                            title: "Left stick",
                            x: server.controllerState.leftX,
                            y: server.controllerState.leftY
                        )
                        
                        stickPreview(
                            title: "Right stick",
                            x: server.controllerState.rightX,
                            y: server.controllerState.rightY
                        )
                        
                        dPadControls
                        
                        VStack(alignment: .leading, spacing: 8) {
                            buttonRow("A", server.controllerState.a)
                            buttonRow("B", server.controllerState.b)
                            buttonRow("X", server.controllerState.x)
                            buttonRow("Y", server.controllerState.y)
                        }
                    }
                    
                    Divider()
                        .overlay(theme.border)
                    
                    HStack {
                        Text("Keyboard mapping")
                            .font(.caption.bold())
                            .foregroundStyle(theme.mutedText)
                        
                        Spacer()
                        
                        Button("Reset") {
                            server.resetBindings()
                        }
                        .font(.caption)
                        .tint(theme.accent)
                    }
                    
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 310), spacing: 10),
                            GridItem(.flexible(minimum: 310), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        ForEach(server.bindings) { binding in
                            mappingChip(binding)
                        }
                    }
                }
                .frame(width: 720)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .preferredColorScheme(.dark)
    }
    
    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(server.permissionStatus.contains("allowed") ? theme.success : theme.warning)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .trailing, spacing: 3) {
                Text(server.permissionStatus)
                    .font(.caption.bold())
                    .foregroundStyle(theme.text)
                
                if !server.permissionStatus.contains("allowed") {
                    Button("Open Settings") {
                        server.requestKeyboardAccess()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private var themeCustomizer: some View {
        Button {
            showingThemeMaker.toggle()
        } label: {
            Label("Theme", systemImage: "paintpalette.fill")
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.raisedPanel)
                .foregroundStyle(theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingThemeMaker, arrowEdge: .bottom) {
            ThemeMakerView(
                selectedPreset: $selectedPreset,
                useCustomTheme: $useCustomTheme,
                customBaseColor: $customBaseColor,
                customAccentColor: $customAccentColor,
                theme: theme
            )
        }
    }
    
    private func stickPreview(title: String, x: Int, y: Int) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.panel)
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.border, lineWidth: 1)
                    )
                
                Circle()
                    .fill((x == 0 && y == 0) ? theme.mutedText.opacity(0.50) : theme.accent)
                    .frame(width: 16, height: 16)
                    .offset(x: CGFloat(x * 22), y: CGFloat(-y * 22))
            }
            
            Text(title)
                .font(.caption2)
                .foregroundStyle(theme.mutedText)
        }
    }
    
    private func buttonRow(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(value == 1 ? theme.accent : theme.panel)
                .foregroundStyle(value == 1 ? theme.background : theme.text)
                .clipShape(Circle())
            
            Text(value == 1 ? "Pressed" : "Ready")
                .font(.caption)
                .foregroundStyle(theme.mutedText)
        }
    }
    
    private var dPadControls: some View {
        VStack(spacing: 7) {
            Text("D-pad")
                .font(.caption2.bold())
                .foregroundStyle(theme.mutedText)
            
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    spacerCell
                    dPadControl(.dPadUp, iconName: "chevron.up", value: server.controllerState.dPadUp)
                    spacerCell
                }
                
                HStack(spacing: 4) {
                    dPadControl(.dPadLeft, iconName: "chevron.left", value: server.controllerState.dPadLeft)
                    Image(systemName: "dpad.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.mutedText)
                        .frame(width: 42, height: 38)
                        .background(theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    dPadControl(.dPadRight, iconName: "chevron.right", value: server.controllerState.dPadRight)
                }
                
                HStack(spacing: 4) {
                    spacerCell
                    dPadControl(.dPadDown, iconName: "chevron.down", value: server.controllerState.dPadDown)
                    spacerCell
                }
            }
        }
    }
    
    private var spacerCell: some View {
        Color.clear
            .frame(width: 42, height: 38)
    }
    
    private func dPadControl(_ control: ControllerControl, iconName: String, value: Int) -> some View {
        let binding = server.bindings.first { $0.control == control }
        let isRemapping = server.remappingControl == control
        
        return Button {
            server.startRemapping(control)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .bold))
                Text(isRemapping ? "..." : (binding?.keyName ?? "-"))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(width: 42, height: 38)
            .background(value == 1 || isRemapping ? theme.accentSoft : theme.panel)
            .foregroundStyle(value == 1 || isRemapping ? theme.accent : theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(value == 1 || isRemapping ? theme.accent.opacity(0.55) : theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Change \(control.title)")
    }
    
    private func mappingChip(_ binding: KeyBinding) -> some View {
        let isRemapping = server.remappingControl == binding.control
        
        return HStack(spacing: 10) {
            Image(systemName: binding.control.iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isRemapping ? theme.accent : theme.mutedText)
                .frame(width: 24)
            
            Text(isRemapping ? "Press key" : binding.keyName)
                .font(.caption.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 72)
                .padding(.vertical, 5)
                .background(isRemapping ? theme.accentSoft : theme.raisedPanel)
                .foregroundStyle(isRemapping ? theme.accent : theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            
            Text(binding.control.title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(isRemapping ? "Press key" : "Change") {
                server.startRemapping(binding.control)
            }
            .font(.caption2)
            .frame(width: 64)
            .tint(theme.accent)
            .disabled(isRemapping)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isRemapping ? theme.accentSoft : theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isRemapping ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
        )
    }
}

struct ThemeMakerView: View {
    @Binding var selectedPreset: ThemePreset
    @Binding var useCustomTheme: Bool
    @Binding var customBaseColor: Color
    @Binding var customAccentColor: Color
    
    let theme: AppTheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Theme maker")
                        .font(.headline)
                        .foregroundStyle(theme.text)
                    Text(useCustomTheme ? "Custom colors" : selectedPreset.name)
                        .font(.caption)
                        .foregroundStyle(theme.mutedText)
                }
                
                Spacer()
                
                Toggle("Custom", isOn: $useCustomTheme)
                    .toggleStyle(.switch)
                    .tint(theme.accent)
            }
            
            Picker("Preset", selection: $selectedPreset) {
                ForEach(ThemePreset.allCases) { preset in
                    Text(preset.name)
                        .tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .disabled(useCustomTheme)
            
            VStack(alignment: .leading, spacing: 10) {
                ColorPicker("Base color", selection: $customBaseColor, supportsOpacity: false)
                    .disabled(!useCustomTheme)
                ColorPicker("Accent color", selection: $customAccentColor, supportsOpacity: false)
                    .disabled(!useCustomTheme)
            }
            .font(.caption.bold())
            .foregroundStyle(theme.text)
            
            HStack(spacing: 8) {
                themeSwatch(theme.background, label: "Base")
                themeSwatch(theme.panel, label: "Panel")
                themeSwatch(theme.raisedPanel, label: "Raised")
                themeSwatch(theme.accent, label: "Accent")
            }
            
            Button {
                customBaseColor = Color(red: 0.070, green: 0.120, blue: 0.200)
                customAccentColor = Color(red: 0.200, green: 0.760, blue: 0.960)
                useCustomTheme = true
            } label: {
                Label("Reset custom colors", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .font(.caption)
            .tint(theme.accent)
        }
        .padding(16)
        .frame(width: 320)
        .background(theme.background)
        .preferredColorScheme(.dark)
    }
    
    private func themeSwatch(_ color: Color, label: String) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color)
                .frame(height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(theme.border, lineWidth: 1)
                )
            
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.mutedText)
        }
    }
}

struct ControllerPreviewView: View {
    let state: ControllerState
    let theme: AppTheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Controller")
                    .font(.title3.bold())
                    .foregroundStyle(theme.text)
                Text("Live preview")
                    .font(.caption)
                    .foregroundStyle(theme.mutedText)
            }
            
            ZStack {
                controllerBody
                triggerRow
                    .offset(y: -124)
                controllerFace
            }
            .frame(width: 390, height: 280)
            
            HStack(spacing: 10) {
                signalPill("LT", state.leftTrigger)
                signalPill("LB", state.lb)
                signalPill("View", state.view)
                signalPill("Menu", state.menu)
                signalPill("RB", state.rb)
                signalPill("RT", state.rightTrigger)
            }
        }
        .padding(22)
        .background(theme.panel.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border, lineWidth: 1)
        )
    }
    
    private var controllerBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 80)
                .fill(theme.panel)
                .frame(width: 350, height: 190)
                .shadow(color: theme.accent.opacity(0.14), radius: 30, x: 0, y: 12)
            
            RoundedRectangle(cornerRadius: 64)
                .fill(theme.panel)
                .frame(width: 150, height: 155)
                .rotationEffect(.degrees(18))
                .offset(x: -112, y: 38)
            
            RoundedRectangle(cornerRadius: 64)
                .fill(theme.panel)
                .frame(width: 150, height: 155)
                .rotationEffect(.degrees(-18))
                .offset(x: 112, y: 38)
            
            RoundedRectangle(cornerRadius: 80)
                .stroke(theme.border, lineWidth: 1.2)
                .frame(width: 350, height: 190)
        }
    }
    
    private var triggerRow: some View {
        HStack(spacing: 64) {
            shoulderButton("LT", state.leftTrigger)
            shoulderButton("LB", state.lb)
            shoulderButton("RB", state.rb)
            shoulderButton("RT", state.rightTrigger)
        }
    }
    
    private var controllerFace: some View {
        ZStack {
            liveStick(title: "L", x: state.leftX, y: state.leftY)
                .offset(x: -105, y: -24)
            
            dPad
                .offset(x: -94, y: 54)
            
            centerButton("View", pressed: state.view == 1)
                .offset(x: -28, y: -14)
            
            centerButton("Menu", pressed: state.menu == 1)
                .offset(x: 28, y: -14)
            
            liveStick(title: "R", x: state.rightX, y: state.rightY)
                .offset(x: 34, y: 52)
            
            faceButton("Y", pressed: state.y == 1)
                .offset(x: 112, y: -52)
            faceButton("X", pressed: state.x == 1)
                .offset(x: 78, y: -18)
            faceButton("B", pressed: state.b == 1)
                .offset(x: 146, y: -18)
            faceButton("A", pressed: state.a == 1)
                .offset(x: 112, y: 16)
        }
        .animation(.easeOut(duration: 0.08), value: state.leftX)
        .animation(.easeOut(duration: 0.08), value: state.leftY)
        .animation(.easeOut(duration: 0.08), value: state.rightX)
        .animation(.easeOut(duration: 0.08), value: state.rightY)
        .animation(.easeOut(duration: 0.08), value: state.a)
        .animation(.easeOut(duration: 0.08), value: state.b)
        .animation(.easeOut(duration: 0.08), value: state.x)
        .animation(.easeOut(duration: 0.08), value: state.y)
        .animation(.easeOut(duration: 0.08), value: state.dPadUp)
        .animation(.easeOut(duration: 0.08), value: state.dPadDown)
        .animation(.easeOut(duration: 0.08), value: state.dPadLeft)
        .animation(.easeOut(duration: 0.08), value: state.dPadRight)
    }
    
    private var dPad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.raisedPanel)
                .frame(width: 18, height: 54)
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.raisedPanel)
                .frame(width: 54, height: 18)
            
            dPadDirection("arrowtriangle.up.fill", pressed: state.dPadUp == 1)
                .offset(y: -18)
            dPadDirection("arrowtriangle.down.fill", pressed: state.dPadDown == 1)
                .offset(y: 18)
            dPadDirection("arrowtriangle.left.fill", pressed: state.dPadLeft == 1)
                .offset(x: -18)
            dPadDirection("arrowtriangle.right.fill", pressed: state.dPadRight == 1)
                .offset(x: 18)
        }
        .overlay(
            Image(systemName: "dpad.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.mutedText)
                .opacity(0.16)
        )
    }
    
    private func dPadDirection(_ icon: String, pressed: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .frame(width: 16, height: 16)
            .background(pressed ? theme.accent : Color.clear)
            .foregroundStyle(pressed ? theme.background : theme.mutedText)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: theme.accent.opacity(pressed ? 0.45 : 0), radius: 8, x: 0, y: 0)
    }
    
    private func liveStick(title: String, x: Int, y: Int) -> some View {
        ZStack {
            Circle()
                .fill(theme.raisedPanel)
                .frame(width: 72, height: 72)
                .overlay(Circle().stroke(theme.border, lineWidth: 1))
            
            Circle()
                .fill((x == 0 && y == 0) ? theme.mutedText.opacity(0.72) : theme.accent)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(title)
                        .font(.caption.bold())
                        .foregroundStyle((x == 0 && y == 0) ? theme.background.opacity(0.75) : theme.background)
                )
                .offset(x: CGFloat(x * 16), y: CGFloat(-y * 16))
                .shadow(color: theme.accent.opacity((x == 0 && y == 0) ? 0 : 0.40), radius: 12, x: 0, y: 0)
        }
    }
    
    private func faceButton(_ label: String, pressed: Bool) -> some View {
        Text(label)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .frame(width: 30, height: 30)
            .background(pressed ? theme.accent : theme.raisedPanel)
            .foregroundStyle(pressed ? theme.background : theme.text)
            .clipShape(Circle())
            .overlay(Circle().stroke(pressed ? theme.accent.opacity(0.7) : theme.border, lineWidth: 1))
            .shadow(color: theme.accent.opacity(pressed ? 0.45 : 0), radius: 12, x: 0, y: 0)
    }
    
    private func centerButton(_ label: String, pressed: Bool) -> some View {
        Image(systemName: label == "View" ? "rectangle.grid.2x2.fill" : "line.3.horizontal")
            .font(.system(size: 11, weight: .bold))
            .frame(width: 34, height: 20)
            .background(pressed ? theme.accent : theme.raisedPanel)
            .foregroundStyle(pressed ? theme.background : theme.mutedText)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(pressed ? theme.accent.opacity(0.7) : theme.border, lineWidth: 1))
    }
    
    private func shoulderButton(_ label: String, _ value: Int) -> some View {
        Text(label)
            .font(.caption.bold())
            .frame(width: 54, height: 24)
            .background(value == 1 ? theme.accent : theme.raisedPanel)
            .foregroundStyle(value == 1 ? theme.background : theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(value == 1 ? theme.accent.opacity(0.7) : theme.border, lineWidth: 1)
            )
    }
    
    private func signalPill(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(value == 1 ? theme.accent : theme.mutedText.opacity(0.35))
                .frame(width: 7, height: 7)
            
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(value == 1 ? theme.text : theme.mutedText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(value == 1 ? theme.accentSoft : theme.background.opacity(0.42))
        .clipShape(Capsule())
    }
}

struct SetupGuideView: View {
    let theme: AppTheme
    
    @State private var copiedCode = false
    
    private let scriptURL = "http://localhost:8026/script"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle("Keyboard access")
                    
                    Spacer()
                    
                    Button {
                        openKeyboardAccessSettings()
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .font(.caption)
                    .tint(theme.accent)
                }
                
                setupStep("1", "Open System Settings, then Privacy & Security.")
                setupStep("2", "Choose Accessibility.")
                setupStep("3", "If CloudController is missing, use + to add it.")
                setupStep("4", "Use - to remove an old entry, then add it again if needed.")
                setupStep("5", "Turn on CloudController.")
                setupStep("6", "If keys still do not register, quit and reopen CloudController.")
            }
            
            Divider()
                .overlay(theme.border)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle("Chrome setup")
                    
                    Spacer()
                    
                    Button {
                        copyToClipboard(BrowserBridgeScript.chromeDevToolsCode)
                        copiedCode = true
                    } label: {
                        Label(copiedCode ? "Copied" : "Copy code", systemImage: copiedCode ? "checkmark" : "doc.on.doc")
                    }
                    .font(.caption)
                    .tint(theme.accent)
                }
                
                setupStep("1", "Open Xbox Cloud Gaming in Chrome.")
                setupStep("2", "Open DevTools with Option + Command + I.")
                setupStep("3", "Paste the code into the Console tab and press Return.")
                setupStep("4", "Keep this app and that Chrome tab open while playing.")
            }
            
            HStack(spacing: 8) {
                Text(scriptURL)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.panel)
                    .foregroundStyle(theme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            
            ScrollView {
                Text(BrowserBridgeScript.chromeDevToolsCode)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .foregroundStyle(theme.text)
                    .padding(10)
            }
            .frame(width: 600, height: 180)
            .background(theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.border, lineWidth: 1)
            )
        }
        .padding(18)
        .frame(width: 640)
        .background(theme.background)
        .preferredColorScheme(.dark)
    }
    
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(theme.text)
    }
    
    private func setupStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(theme.accentSoft)
                .foregroundStyle(theme.accent)
                .clipShape(Circle())
            
            Text(text)
                .font(.caption)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func openKeyboardAccessSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        
        for urlString in settingsURLs {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                break
            }
        }
    }
}













































































































