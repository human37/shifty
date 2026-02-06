import AppKit

struct ShiftOption: Codable, Equatable {
    let label: String
    let icon: String
}

struct AppConfig: Codable {
    let options: [ShiftOption]
    let intervalMinMinutes: Int
    let intervalMaxMinutes: Int
}

struct PersistedState: Codable {
    let currentLabel: String
    let queueLabels: [String]
    let nextChange: Date
}

final class ShiftyApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let currentItem = NSMenuItem(title: "Current: --", action: nil, keyEquivalent: "")
    private let nextChangeItem = NSMenuItem(title: "Next change: --", action: nil, keyEquivalent: "")
    private let optionsMenuItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
    private let optionsSubmenu = NSMenu()
    private var options: [ShiftOption] = []
    private var currentLabel: String?
    private var nextChange = Date()
    private var queue: [ShiftOption] = []
    private var baseTitle = ""
    private var tickTimer: Timer?
    private var flashTimer: Timer?
    private let fileManager = FileManager.default
    private lazy var appSupportDirectory: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Shifty", isDirectory: true)
    }()
    private lazy var configURL: URL = appSupportDirectory.appendingPathComponent("config.json")
    private lazy var stateURL: URL = appSupportDirectory.appendingPathComponent("state.json")
    private let defaultConfig = AppConfig(
        options: [
            ShiftOption(label: "STAND", icon: "🧍"),
            ShiftOption(label: "SIT", icon: "💺"),
        ],
        intervalMinMinutes: 50,
        intervalMaxMinutes: 70
    )
    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.addItem(currentItem)
        menu.addItem(nextChangeItem)
        menu.addItem(NSMenuItem.separator())
        optionsMenuItem.submenu = optionsSubmenu
        menu.addItem(optionsMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        let config = loadConfig()
        options = normalizedOptions(from: config)
        rebuildOptionsMenu()
        restoreOrInitializeState(config: config)
        tickTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    private func ensureAppSupportDirectory() {
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
    }

    private func normalizedOptions(from config: AppConfig) -> [ShiftOption] {
        var seen = Set<String>()
        let normalized = config.options.compactMap { option -> ShiftOption? in
            let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !label.isEmpty, !seen.contains(label) else { return nil }
            seen.insert(label)
            return ShiftOption(label: label, icon: option.icon.isEmpty ? "🔁" : option.icon)
        }
        return normalized.isEmpty ? defaultConfig.options : normalized
    }

    private func sanitizedIntervalRange(from config: AppConfig) -> ClosedRange<Int> {
        let minMinutes = max(1, config.intervalMinMinutes)
        let maxMinutes = max(minMinutes, config.intervalMaxMinutes)
        return minMinutes...maxMinutes
    }

    private func loadConfig() -> AppConfig {
        ensureAppSupportDirectory()
        if let data = try? Data(contentsOf: configURL),
           let config = try? decoder.decode(AppConfig.self, from: data) {
            return config
        }
        saveConfig(defaultConfig)
        return defaultConfig
    }

    private func saveConfig(_ config: AppConfig) {
        ensureAppSupportDirectory()
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    private func loadState() -> PersistedState? {
        ensureAppSupportDirectory()
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(PersistedState.self, from: data) else {
            return nil
        }
        return state
    }

    private func saveState() {
        guard let currentLabel else { return }
        ensureAppSupportDirectory()
        let state = PersistedState(currentLabel: currentLabel, queueLabels: queue.map(\.label), nextChange: nextChange)
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func restoreOrInitializeState(config: AppConfig) {
        if let state = loadState(),
           let current = option(label: state.currentLabel) {
            currentLabel = current.label
            baseTitle = "\(current.icon) \(current.label)"
            statusItem.button?.title = baseTitle
            currentItem.title = "Current: \(current.label)"
            queue = queueFromLabels(state.queueLabels)
            nextChange = state.nextChange
            refreshNextChangeMenu()
            if Date() >= nextChange {
                setRandomState(initial: false)
            } else {
                saveState()
            }
            return
        }
        setRandomState(initial: true)
    }

    private func option(label: String) -> ShiftOption? {
        options.first(where: { $0.label == label.uppercased() })
    }

    private func queueFromLabels(_ labels: [String]) -> [ShiftOption] {
        var used = Set<String>()
        var result: [ShiftOption] = []
        for label in labels {
            guard let option = option(label: label), !used.contains(option.label) else { continue }
            used.insert(option.label)
            result.append(option)
        }
        let missing = options.filter { !used.contains($0.label) }.shuffled()
        return result + missing
    }

    private func refillQueue() {
        var items = options.shuffled()
        if let currentLabel, items.first?.label == currentLabel, items.count > 1 {
            items.swapAt(0, 1)
        }
        queue = items
    }

    private func setRandomState(initial: Bool) {
        if queue.isEmpty {
            refillQueue()
        }

        let state = queue.removeFirst()
        currentLabel = state.label
        baseTitle = "\(state.icon) \(state.label)"
        statusItem.button?.title = baseTitle
        currentItem.title = "Current: \(state.label)"

        let config = loadConfig()
        let intervalRange = sanitizedIntervalRange(from: config)
        nextChange = Date().addingTimeInterval(Double(Int.random(in: intervalRange) * 60))
        refreshNextChangeMenu()
        saveState()

        if !initial {
            sendNotification(body: baseTitle)
            flashTitle()
        }
    }

    private func sendNotification(body: String) {
        let script = "display notification \"\(body.replacingOccurrences(of: "\"", with: "\\\""))\" with title \"Shifty\" subtitle \"Time to shift\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func flashTitle() {
        guard let currentLabel else { return }
        statusItem.button?.title = "⏰ \(currentLabel)"
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.statusItem.button?.title = self?.baseTitle ?? ""
        }
    }

    private func refreshNextChangeMenu() {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        nextChangeItem.title = "Next change: \(formatter.string(from: nextChange))"
    }

    private func rebuildOptionsMenu() {
        optionsSubmenu.removeAllItems()
        let addItem = NSMenuItem(title: "Add Option...", action: #selector(addOption), keyEquivalent: "")
        addItem.target = self
        optionsSubmenu.addItem(addItem)
        optionsSubmenu.addItem(NSMenuItem.separator())
        for option in options {
            let item = NSMenuItem(title: "\(option.icon) \(option.label)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            optionsSubmenu.addItem(item)
        }
    }

    private func persistOptionsToConfig() {
        let config = loadConfig()
        let updated = AppConfig(
            options: options,
            intervalMinMinutes: config.intervalMinMinutes,
            intervalMaxMinutes: config.intervalMaxMinutes
        )
        saveConfig(updated)
    }

    @objc private func addOption() {
        let rawLabel = promptForInput(
            title: "Add Option",
            message: "Label (example: WALK)",
            confirmTitle: "Next",
            placeholder: "WALK"
        )
        guard let rawLabel else { return }
        let normalizedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedLabel.isEmpty else { return }
        guard option(label: normalizedLabel) == nil else { return }

        let rawIcon = promptForInput(
            title: "Add Option",
            message: "Icon (optional, example: 🚶)",
            confirmTitle: "Add",
            placeholder: "🚶"
        )
        let normalizedIcon = (rawIcon ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newOption = ShiftOption(label: normalizedLabel, icon: normalizedIcon.isEmpty ? "🔁" : normalizedIcon)
        options.append(newOption)
        queue.append(newOption)
        persistOptionsToConfig()
        rebuildOptionsMenu()
        saveState()
    }

    private func promptForInput(title: String, message: String, confirmTitle: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        let field = NSTextField(frame: .zero)
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 24)
        ])
        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    @objc private func tick() {
        if Date() >= nextChange {
            setRandomState(initial: false)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = ShiftyApp()
app.delegate = delegate
app.run()
