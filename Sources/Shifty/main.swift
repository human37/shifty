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

final class ShiftyApp: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
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
    private var tickTimer: Timer?
    private var flashTimer: Timer?
    private weak var emojiTargetField: NSTextField?
    private weak var emojiPreviewLabel: NSTextField?
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
        menu.delegate = self

        let config = loadConfig()
        options = normalizedOptions(from: config)
        rebuildOptionsMenu()
        restoreOrInitializeState(config: config)
        tickTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        tickTimer?.tolerance = 10 // lets macOS coalesce wakeups
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
            queue = queueFromLabels(state.queueLabels)
            nextChange = state.nextChange
            refreshStatus()
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

        let config = loadConfig()
        let intervalRange = sanitizedIntervalRange(from: config)
        nextChange = Date().addingTimeInterval(Double(Int.random(in: intervalRange) * 60))
        saveState()

        if !initial {
            sendNotification(body: state.label)
            flashTitle()
        }
        refreshStatus()
    }

    private func sendNotification(body: String) {
        let script = "display notification \"\(body.replacingOccurrences(of: "\"", with: "\\\""))\" with title \"Shifty\" subtitle \"Time to shift\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func flashTitle() {
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.flashTimer = nil
            self?.refreshStatus()
        }
    }

    // Pose name followed by a filled pill with the countdown cut out of it; template so it follows the menu bar colour.
    private func badgeImage(name: String, badge: String) -> NSImage {
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0)]
        let badgeAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]
        let nameSize = (name as NSString).size(withAttributes: nameAttrs)
        let badgeSize = (badge as NSString).size(withAttributes: badgeAttrs)
        let pill = NSRect(x: ceil(nameSize.width) + 5, y: 1.5, width: ceil(badgeSize.width) + 10, height: 15)
        let image = NSImage(size: NSSize(width: pill.maxX, height: 18), flipped: false) { _ in
            (name as NSString).draw(at: NSPoint(x: 0, y: (18 - nameSize.height) / 2), withAttributes: nameAttrs)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            (badge as NSString).draw(at: NSPoint(x: pill.midX - badgeSize.width / 2, y: pill.midY - badgeSize.height / 2), withAttributes: badgeAttrs)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func refreshStatus() {
        guard let current = currentLabel.flatMap(option(label:)) else { return }
        let countdown = "\(max(0, Int((nextChange.timeIntervalSinceNow / 60).rounded(.up))))m"
        // The badge reads NOW for a few seconds after a change.
        let image = badgeImage(name: current.label, badge: flashTimer == nil ? countdown : "NOW")
        image.accessibilityDescription = "\(current.label), next change in \(countdown)"
        statusItem.button?.image = image
        currentItem.title = "Current: \(current.label)"
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        nextChangeItem.title = "Next change: \(formatter.string(from: nextChange)) (\(countdown))"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
    }

    private func rebuildOptionsMenu() {
        optionsSubmenu.removeAllItems()
        let addItem = NSMenuItem(title: "Add Option...", action: #selector(addOption), keyEquivalent: "")
        addItem.target = self
        let removeItem = NSMenuItem(title: "Remove Option...", action: #selector(removeOption), keyEquivalent: "")
        removeItem.target = self
        let frequencyItem = NSMenuItem(title: "Set Frequency...", action: #selector(setFrequency), keyEquivalent: "")
        frequencyItem.target = self
        let config = loadConfig()
        let frequencyStatusItem = NSMenuItem(
            title: "Frequency: \(config.intervalMinMinutes)-\(config.intervalMaxMinutes) min",
            action: nil,
            keyEquivalent: ""
        )
        frequencyStatusItem.isEnabled = false
        optionsSubmenu.addItem(addItem)
        optionsSubmenu.addItem(removeItem)
        optionsSubmenu.addItem(frequencyItem)
        optionsSubmenu.addItem(NSMenuItem.separator())
        optionsSubmenu.addItem(frequencyStatusItem)
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
        guard let (rawLabel, rawIcon) = promptForNewOption() else { return }
        let normalizedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedLabel.isEmpty else { return }
        guard option(label: normalizedLabel) == nil else { return }
        let normalizedIcon = rawIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        let newOption = ShiftOption(label: normalizedLabel, icon: normalizedIcon.isEmpty ? "🔁" : normalizedIcon)
        options.append(newOption)
        queue.append(newOption)
        persistOptionsToConfig()
        rebuildOptionsMenu()
        saveState()
    }

    @objc private func removeOption() {
        guard options.count > 1 else {
            showAlert(title: "Cannot Remove Option", message: "At least one posture option is required.")
            return
        }

        let rawLabel = promptForInput(
            title: "Remove Option",
            message: "Label to remove (example: SIT)",
            confirmTitle: "Remove",
            placeholder: options.last?.label ?? "SIT"
        )
        guard let rawLabel else { return }
        let normalizedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let index = options.firstIndex(where: { $0.label == normalizedLabel }) else {
            showAlert(title: "Option Not Found", message: "No option named \(normalizedLabel).")
            return
        }

        let removed = options.remove(at: index)
        queue.removeAll(where: { $0.label == removed.label })
        persistOptionsToConfig()
        rebuildOptionsMenu()

        if currentLabel == removed.label {
            setRandomState(initial: true)
            return
        }

        saveState()
    }

    @objc private func setFrequency() {
        let existing = sanitizedIntervalRange(from: loadConfig())
        let rawMin = promptForInput(
            title: "Set Frequency",
            message: "Minimum minutes between changes",
            confirmTitle: "Next",
            placeholder: "\(existing.lowerBound)"
        )
        guard let rawMin else { return }
        guard let minMinutes = Int(rawMin.trimmingCharacters(in: .whitespacesAndNewlines)), minMinutes >= 1 else {
            showAlert(title: "Invalid Minimum", message: "Minimum must be a whole number of at least 1.")
            return
        }

        let rawMax = promptForInput(
            title: "Set Frequency",
            message: "Maximum minutes between changes",
            confirmTitle: "Save",
            placeholder: "\(max(existing.upperBound, minMinutes))"
        )
        guard let rawMax else { return }
        guard let maxMinutes = Int(rawMax.trimmingCharacters(in: .whitespacesAndNewlines)), maxMinutes >= minMinutes else {
            showAlert(title: "Invalid Maximum", message: "Maximum must be a whole number greater than or equal to minimum.")
            return
        }

        saveConfig(AppConfig(
            options: options,
            intervalMinMinutes: minMinutes,
            intervalMaxMinutes: maxMinutes
        ))
        nextChange = Date().addingTimeInterval(Double(Int.random(in: minMinutes...maxMinutes) * 60))
        refreshStatus()
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

    private func promptForNewOption() -> (String, String)? {
        let alert = NSAlert()
        alert.messageText = "Add Option"
        alert.informativeText = "Add a new posture option."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 72))
        let labelField = NSTextField(frame: .zero)
        labelField.placeholderString = "Label (example: WALK)"
        let iconValue = NSTextField(labelWithString: "🔁")
        iconValue.alignment = .center
        iconValue.font = NSFont.systemFont(ofSize: 20)
        let hiddenIconField = NSTextField(frame: .zero)
        hiddenIconField.isHidden = true
        hiddenIconField.delegate = self
        let emojiButton = NSButton(title: "Pick Emoji...", target: self, action: #selector(openEmojiPicker))
        emojiButton.setButtonType(.momentaryPushIn)
        emojiButton.bezelStyle = .rounded

        let labelTitle = NSTextField(labelWithString: "Label")
        let iconTitle = NSTextField(labelWithString: "Icon")
        let row = NSStackView(views: [labelField, iconValue, emojiButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = .fill

        let titles = NSStackView(views: [labelTitle, iconTitle])
        titles.orientation = .horizontal
        titles.spacing = 8
        titles.distribution = .fillProportionally

        let content = NSStackView(views: [titles, row])
        content.orientation = .vertical
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        container.addSubview(hiddenIconField)

        labelField.translatesAutoresizingMaskIntoConstraints = false
        iconValue.translatesAutoresizingMaskIntoConstraints = false
        emojiButton.translatesAutoresizingMaskIntoConstraints = false
        hiddenIconField.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            labelField.widthAnchor.constraint(equalToConstant: 230),
            iconValue.widthAnchor.constraint(equalToConstant: 52),
            emojiButton.widthAnchor.constraint(equalToConstant: 90),
            hiddenIconField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hiddenIconField.topAnchor.constraint(equalTo: container.topAnchor),
            hiddenIconField.widthAnchor.constraint(equalToConstant: 0),
            hiddenIconField.heightAnchor.constraint(equalToConstant: 0)
        ])

        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        emojiTargetField = hiddenIconField
        emojiPreviewLabel = iconValue
        alert.window.initialFirstResponder = labelField
        let response = alert.runModal()
        emojiTargetField = nil
        emojiPreviewLabel = nil
        guard response == .alertFirstButtonReturn else { return nil }
        return (labelField.stringValue, hiddenIconField.stringValue)
    }

    @objc private func openEmojiPicker() {
        guard let field = emojiTargetField else { return }
        field.window?.makeFirstResponder(field)
        NSApp.orderFrontCharacterPalette(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === emojiTargetField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastCharacter = trimmed.last else { return }
        let emoji = String(lastCharacter)
        field.stringValue = emoji
        emojiPreviewLabel?.stringValue = emoji
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func tick() {
        if Date() >= nextChange {
            setRandomState(initial: false)
        } else {
            refreshStatus()
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
