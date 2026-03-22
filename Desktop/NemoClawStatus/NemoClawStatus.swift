// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// NemoClaw Hub — macOS command center for NemoClaw
// Full dashboard: services, sandbox, inference, policies, bridges, sync, credentials, logs.
// v2.1 — Interactive policies, live logs, Telegram remote, onboard wizard, notifications.

import Cocoa
import Foundation
import UserNotifications

// ═══════════════════════════════════════════
// MARK: - Shell Helpers
// ═══════════════════════════════════════════

let kHome = NSHomeDirectory()
let kNemoDir = "\(kHome)/.nemoclaw"
let kDashboardURL = "http://127.0.0.1:18789"

func shell(_ cmd: String, timeout: TimeInterval = 10) -> String {
    let proc = Process()
    let pipe = Pipe()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = ["-lc", cmd]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    var env = ProcessInfo.processInfo.environment
    let localBin = "\(kHome)/.local/bin"
    let existing = env["PATH"] ?? "/usr/bin:/bin"
    env["PATH"] = "\(localBin):/opt/homebrew/bin:/usr/local/bin:\(existing)"
    proc.environment = env
    do { try proc.run() } catch { return "" }
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { proc.waitUntilExit(); group.leave() }
    if group.wait(timeout: .now() + timeout) == .timedOut { proc.terminate(); return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func shellAsync(_ cmd: String, timeout: TimeInterval = 10, completion: @escaping (String) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let result = shell(cmd, timeout: timeout)
        DispatchQueue.main.async { completion(result) }
    }
}

// ═══════════════════════════════════════════
// MARK: - Data Models
// ═══════════════════════════════════════════

struct SandboxInfo {
    var name: String
    var isDefault: Bool
    var model: String
    var provider: String
    var gpuEnabled: Bool
    var policies: [String]
}

struct ServiceStatus {
    var name: String
    var running: Bool
    var pid: String
    var detail: String
}

struct CredentialEntry {
    var key: String
    var label: String
    var hasValue: Bool
    var hint: String
}

struct GPUInfo {
    var chipName: String
    var vram: String
    var cores: String
    var nimCapable: Bool
}

// ═══════════════════════════════════════════
// MARK: - Data Provider
// ═══════════════════════════════════════════

class NemoClawDataProvider {
    static let shared = NemoClawDataProvider()

    func loadSandboxes() -> [SandboxInfo] {
        let path = "\(kNemoDir)/sandboxes.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sandboxes = json["sandboxes"] as? [[String: Any]] else { return [] }
        let defaultName = json["default"] as? String ?? ""
        return sandboxes.map { s in
            SandboxInfo(
                name: s["name"] as? String ?? "unknown",
                isDefault: (s["name"] as? String) == defaultName,
                model: s["model"] as? String ?? "-",
                provider: s["provider"] as? String ?? "-",
                gpuEnabled: s["gpuEnabled"] as? Bool ?? false,
                policies: s["policies"] as? [String] ?? []
            )
        }
    }

    func sandboxStatus(_ name: String, completion: @escaping (String) -> Void) {
        shellAsync("openshell sandbox list 2>/dev/null | grep -i '\(name)' | head -1") { line in
            if line.lowercased().contains("running") { completion("Running") }
            else if line.lowercased().contains("ready") { completion("Ready") }
            else if line.isEmpty { completion("Unknown") }
            else { completion(line) }
        }
    }

    func serviceStatuses(sandbox: String, completion: @escaping ([ServiceStatus]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pidDir = "/tmp/nemoclaw-services-\(sandbox)"
            var results: [ServiceStatus] = []
            for svc in ["telegram-bridge", "cloudflared"] {
                let pidFile = "\(pidDir)/\(svc).pid"
                let logFile = "\(pidDir)/\(svc).log"
                var running = false; var pid = ""; var detail = ""
                if let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) {
                    pid = pidStr
                    running = shell("kill -0 \(pidStr) 2>/dev/null && echo alive || echo dead") == "alive"
                }
                if FileManager.default.fileExists(atPath: logFile) {
                    detail = shell("tail -1 '\(logFile)' 2>/dev/null")
                }
                let label = svc == "telegram-bridge" ? "Telegram Bridge" : "Cloudflare Tunnel"
                results.append(ServiceStatus(name: label, running: running, pid: pid, detail: detail))
            }
            DispatchQueue.main.async { completion(results) }
        }
    }

    func loadCredentials() -> [CredentialEntry] {
        let path = "\(kNemoDir)/credentials.json"
        var creds: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            creds = json
        }
        let defs: [(key: String, label: String, hint: String)] = [
            ("NVIDIA_API_KEY", "NVIDIA API Key", "nvapi-... from build.nvidia.com"),
            ("GITHUB_TOKEN", "GitHub Token", "PAT or gh auth token"),
            ("TELEGRAM_BOT_TOKEN", "Telegram Bot Token", "From @BotFather"),
            ("DISCORD_BOT_TOKEN", "Discord Bot Token", "From Discord Developer Portal"),
            ("SLACK_BOT_TOKEN", "Slack Bot Token", "From Slack App Directory"),
        ]
        return defs.map { d in
            let envVal = ProcessInfo.processInfo.environment[d.key]
            let fileVal = creds[d.key]
            let hasValue = (envVal != nil && !envVal!.isEmpty) || (fileVal != nil && !fileVal!.isEmpty)
            return CredentialEntry(key: d.key, label: d.label, hasValue: hasValue, hint: d.hint)
        }
    }

    func detectGPU(completion: @escaping (GPUInfo) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let nv = shell("nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null")
            if !nv.isEmpty {
                let parts = nv.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                DispatchQueue.main.async {
                    completion(GPUInfo(chipName: parts.first ?? "NVIDIA GPU",
                                      vram: parts.count > 1 ? parts[1] : "?",
                                      cores: "-", nimCapable: true))
                }
                return
            }
            let raw = shell("system_profiler SPDisplaysDataType 2>/dev/null")
            var chip = "Unknown"; var cores = "-"; var vram = "-"
            for line in raw.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Chipset Model:") { chip = t.replacingOccurrences(of: "Chipset Model: ", with: "") }
                if t.hasPrefix("Total Number of Cores:") { cores = t.replacingOccurrences(of: "Total Number of Cores: ", with: "") }
            }
            if let bytes = UInt64(shell("sysctl -n hw.memsize 2>/dev/null")) {
                vram = "\(bytes / (1024*1024*1024)) GB Unified"
            }
            DispatchQueue.main.async {
                completion(GPUInfo(chipName: chip, vram: vram, cores: cores, nimCapable: false))
            }
        }
    }

    func checkUpstreamSync(repoPath: String, completion: @escaping (Int, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fetch = shell("cd '\(repoPath)' && git fetch upstream 2>/dev/null && echo ok || echo fail", timeout: 15)
            guard fetch == "ok" else {
                DispatchQueue.main.async { completion(-1, "fetch failed") }
                return
            }
            let count = Int(shell("cd '\(repoPath)' && git rev-list --count HEAD..upstream/main 2>/dev/null")) ?? 0
            let result = count == 0 ? "up-to-date" : "\(count) behind"
            DispatchQueue.main.async { completion(count, result) }
        }
    }

    func listPolicyPresets(repoPath: String) -> [(name: String, file: String)] {
        let dir = "\(repoPath)/nemoclaw-blueprint/policies/presets"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".yaml") }.sorted().map { f in
            (name: f.replacingOccurrences(of: ".yaml", with: ""), file: f)
        }
    }

    func checkDashboard(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: kDashboardURL) else { completion(false); return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    func recentLogs(sandbox: String, lines: Int = 80, completion: @escaping (String) -> Void) {
        shellAsync("openshell sandbox logs \(sandbox) 2>/dev/null | tail -\(lines)") { completion($0) }
    }
}

// ═══════════════════════════════════════════
// MARK: - Notifications Manager
// ═══════════════════════════════════════════

class HubNotificationManager {
    static let shared = HubNotificationManager()
    private var lastDashboardUp: Bool?
    private var lastSyncBehind: Int?
    private var lastBridgeStates: [String: Bool] = [:]

    func setup() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func checkAndNotify(dashboardUp: Bool, syncBehind: Int, services: [ServiceStatus]) {
        // Dashboard went down
        if let prev = lastDashboardUp, prev && !dashboardUp {
            send(title: "Dashboard Offline", body: "The NemoClaw dashboard at localhost:18789 is no longer responding.")
        }
        // Dashboard came back
        if let prev = lastDashboardUp, !prev && dashboardUp {
            send(title: "Dashboard Online", body: "The NemoClaw dashboard is back up.")
        }
        lastDashboardUp = dashboardUp

        // New upstream commits
        if let prev = lastSyncBehind, prev == 0 && syncBehind > 0 {
            send(title: "Upstream Update", body: "\(syncBehind) new commit\(syncBehind == 1 ? "" : "s") from NVIDIA/NemoClaw.")
        }
        lastSyncBehind = syncBehind

        // Bridge crashed
        for svc in services {
            let key = svc.name.lowercased()
            if let prev = lastBridgeStates[key], prev && !svc.running {
                send(title: "\(svc.name) Stopped", body: "\(svc.name) has stopped running. Check the logs for details.")
            }
            lastBridgeStates[key] = svc.running
        }
    }

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// ═══════════════════════════════════════════
// MARK: - Sidebar Section Enum
// ═══════════════════════════════════════════

enum HubSection: String, CaseIterable {
    case overview    = "Overview"
    case sandboxes   = "Sandboxes"
    case inference   = "Inference"
    case policies    = "Policies"
    case bridges     = "Bridges"
    case telegram    = "Telegram Remote"
    case sync        = "Upstream Sync"
    case credentials = "Credentials"
    case logs        = "Logs"

    var icon: String {
        switch self {
        case .overview:    return "gauge.with.dots.needle.33percent"
        case .sandboxes:   return "shippingbox.fill"
        case .inference:   return "brain.head.profile"
        case .policies:    return "network.badge.shield.half.filled"
        case .bridges:     return "message.fill"
        case .telegram:    return "paperplane.fill"
        case .sync:        return "arrow.triangle.2.circlepath"
        case .credentials: return "key.fill"
        case .logs:        return "doc.text.fill"
        }
    }
}

// ═══════════════════════════════════════════
// MARK: - Theme
// ═══════════════════════════════════════════

let kNvidiaGreen  = NSColor(red: 0.46, green: 0.73, blue: 0.0, alpha: 1.0)
let kBgDark       = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
let kBgCard       = NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1.0)
let kBgSidebar    = NSColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1.0)
let kTextPrimary  = NSColor.white
let kTextSecondary = NSColor(white: 0.6, alpha: 1.0)
let kAccentRed    = NSColor(red: 0.95, green: 0.30, blue: 0.30, alpha: 1.0)
let kAccentYellow = NSColor(red: 1.0, green: 0.78, blue: 0.0, alpha: 1.0)

// ═══════════════════════════════════════════
// MARK: - UI Factory
// ═══════════════════════════════════════════

func makeLabel(_ text: String, size: CGFloat = 13, color: NSColor = kTextPrimary,
               bold: Bool = false, mono: Bool = false, wrap: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    if mono { l.font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) }
    else    { l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size) }
    l.textColor = color; l.backgroundColor = .clear; l.isBezeled = false; l.isEditable = false
    if wrap { l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 0 }
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func makeCard() -> NSView {
    let v = NSView(); v.wantsLayer = true
    v.layer?.backgroundColor = kBgCard.cgColor; v.layer?.cornerRadius = 10
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
}

func makeButton(_ title: String, action: Selector, target: AnyObject) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded; b.controlSize = .regular
    b.translatesAutoresizingMaskIntoConstraints = false; b.contentTintColor = kNvidiaGreen
    return b
}

func statusDot(_ on: Bool) -> NSView {
    let v = NSView(); v.wantsLayer = true; v.layer?.cornerRadius = 5
    v.layer?.backgroundColor = (on ? kNvidiaGreen : kAccentRed).cgColor
    v.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 10),
                                 v.heightAnchor.constraint(equalToConstant: 10)])
    return v
}

func makeBadge(_ text: String, color: NSColor) -> NSTextField {
    let b = NSTextField(labelWithString: "  \(text)  ")
    b.font = NSFont.boldSystemFont(ofSize: 10); b.textColor = .white
    b.wantsLayer = true; b.layer?.backgroundColor = color.cgColor
    b.layer?.cornerRadius = 4; b.layer?.masksToBounds = true
    b.isBezeled = false; b.isEditable = false; b.translatesAutoresizingMaskIntoConstraints = false
    return b
}

func sfImage(_ name: String, size: CGFloat = 16, color: NSColor = kNvidiaGreen) -> NSImageView? {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let iv = NSImageView(image: img.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: size, weight: .medium))!)
    iv.contentTintColor = color; iv.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([iv.widthAnchor.constraint(equalToConstant: size + 4),
                                 iv.heightAnchor.constraint(equalToConstant: size + 4)])
    return iv
}

// ═══════════════════════════════════════════
// MARK: - Hub Window Controller
// ═══════════════════════════════════════════

class HubWindowController: NSWindowController {

    let sidebar = NSTableView()
    let contentBox = NSView()
    let data = NemoClawDataProvider.shared
    var selected: HubSection = .overview
    var refreshTimer: Timer?
    var logStreamTimer: Timer?
    var logTextView: NSTextView?

    // State
    var dashboardUp = false
    var sandboxes: [SandboxInfo] = []
    var services: [ServiceStatus] = []
    var credentials: [CredentialEntry] = []
    var gpuInfo: GPUInfo?
    var syncBehind = -1
    var syncLabel = "Checking..."
    var syncChecked: Date?
    var policyPresets: [(name: String, file: String)] = []
    var policyChecks: [String: Bool] = [:]  // preset name -> enabled
    var telegramChatLog: [String] = []

    var repoPath: String {
        let custom = shell("cat '\(kHome)/.nemoclaw/repo-path' 2>/dev/null")
        return custom.isEmpty ? "\(kHome)/Documents/GitHub/NemoClaw" : custom
    }

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "NemoClaw Hub"
        w.center()
        w.minSize = NSSize(width: 800, height: 520)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.backgroundColor = kBgDark
        w.appearance = NSAppearance(named: .darkAqua)
        self.init(window: w)
        buildLayout()
        initPolicyState()
        refreshAll()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    func initPolicyState() {
        let defaultSb = sandboxes.first(where: { $0.isDefault }) ?? sandboxes.first
        let activePolicies = defaultSb?.policies ?? []
        for preset in policyPresets {
            policyChecks[preset.name] = activePolicies.contains(preset.name)
        }
    }

    // ── Layout ─────────────────────────────

    func buildLayout() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true; root.layer?.backgroundColor = kBgDark.cgColor

        let sideScroll = NSScrollView()
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        sideScroll.hasVerticalScroller = true; sideScroll.drawsBackground = false

        sidebar.dataSource = self; sidebar.delegate = self
        sidebar.headerView = nil; sidebar.backgroundColor = .clear
        sidebar.rowHeight = 36; sidebar.selectionHighlightStyle = .regular; sidebar.style = .plain
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("s"))
        col.width = 184
        sidebar.addTableColumn(col)
        sideScroll.documentView = sidebar

        let sideWrap = NSView()
        sideWrap.wantsLayer = true; sideWrap.layer?.backgroundColor = kBgSidebar.cgColor
        sideWrap.translatesAutoresizingMaskIntoConstraints = false

        let logo = makeLabel("NemoClaw", size: 16, color: kNvidiaGreen, bold: true)
        let version = makeLabel("Hub v2.1", size: 10, color: kTextSecondary)
        sideWrap.addSubview(logo); sideWrap.addSubview(version); sideWrap.addSubview(sideScroll)

        contentBox.translatesAutoresizingMaskIntoConstraints = false
        contentBox.wantsLayer = true; contentBox.layer?.backgroundColor = kBgDark.cgColor

        root.addSubview(sideWrap); root.addSubview(contentBox)

        NSLayoutConstraint.activate([
            sideWrap.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sideWrap.topAnchor.constraint(equalTo: root.topAnchor),
            sideWrap.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideWrap.widthAnchor.constraint(equalToConstant: 200),
            logo.centerXAnchor.constraint(equalTo: sideWrap.centerXAnchor),
            logo.topAnchor.constraint(equalTo: sideWrap.topAnchor, constant: 16),
            version.centerXAnchor.constraint(equalTo: sideWrap.centerXAnchor),
            version.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 2),
            sideScroll.leadingAnchor.constraint(equalTo: sideWrap.leadingAnchor, constant: 8),
            sideScroll.trailingAnchor.constraint(equalTo: sideWrap.trailingAnchor, constant: -8),
            sideScroll.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 10),
            sideScroll.bottomAnchor.constraint(equalTo: sideWrap.bottomAnchor),
            contentBox.leadingAnchor.constraint(equalTo: sideWrap.trailingAnchor),
            contentBox.topAnchor.constraint(equalTo: root.topAnchor),
            contentBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    // ── Data Refresh ───────────────────────

    func refreshAll() {
        sandboxes = data.loadSandboxes()
        credentials = data.loadCredentials()
        policyPresets = data.listPolicyPresets(repoPath: repoPath)
        if policyChecks.isEmpty { initPolicyState() }

        data.checkDashboard { [weak self] ok in self?.dashboardUp = ok; self?.renderIfNeeded() }

        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? sandboxes.first?.name ?? "nemoclaw"
        data.serviceStatuses(sandbox: sb) { [weak self] s in
            self?.services = s
            // Fire notifications
            if let self = self {
                HubNotificationManager.shared.checkAndNotify(
                    dashboardUp: self.dashboardUp,
                    syncBehind: self.syncBehind,
                    services: self.services
                )
            }
            self?.renderIfNeeded()
        }
        data.detectGPU { [weak self] g in self?.gpuInfo = g; self?.renderIfNeeded() }
        data.checkUpstreamSync(repoPath: repoPath) { [weak self] n, lbl in
            self?.syncBehind = n; self?.syncLabel = lbl; self?.syncChecked = Date(); self?.renderIfNeeded()
        }
    }

    func renderIfNeeded() {
        // Only re-render if we're not on the logs panel (to avoid disrupting live stream)
        if selected == .logs && logTextView != nil { return }
        render()
    }

    // ── Main Render ────────────────────────

    func render() {
        logStreamTimer?.invalidate(); logStreamTimer = nil; logTextView = nil
        contentBox.subviews.forEach { $0.removeFromSuperview() }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        let panel = NSView(); panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true

        switch selected {
        case .overview:    buildOverview(panel)
        case .sandboxes:   buildSandboxes(panel)
        case .inference:   buildInference(panel)
        case .policies:    buildPolicies(panel)
        case .bridges:     buildBridges(panel)
        case .telegram:    buildTelegramRemote(panel)
        case .sync:        buildSync(panel)
        case .credentials: buildCredentials(panel)
        case .logs:        buildLogs(panel)
        }

        scroll.documentView = panel
        contentBox.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentBox.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            panel.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
    }

    // ─────────────────────────────────────────
    // MARK: Overview
    // ─────────────────────────────────────────

    func buildOverview(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Overview", size: 22, bold: true), to: p, x: 24, y: y); y += 42

        // Status row
        let cards: [(String, String, NSColor)] = [
            ("Dashboard", dashboardUp ? "Online" : "Offline", dashboardUp ? kNvidiaGreen : kAccentRed),
            ("Sandboxes", "\(sandboxes.count)", kNvidiaGreen),
            ("GPU", gpuInfo?.chipName ?? "...", kAccentYellow),
            ("Upstream", syncLabel, syncBehind == 0 ? kNvidiaGreen : kAccentYellow),
        ]
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.distribution = .fillEqually; row.translatesAutoresizingMaskIntoConstraints = false
        for (lbl, val, col) in cards {
            let c = makeCard()
            let l1 = makeLabel(lbl, size: 11, color: kTextSecondary)
            let l2 = makeLabel(val, size: 16, color: col, bold: true)
            c.addSubview(l1); c.addSubview(l2)
            NSLayoutConstraint.activate([
                l1.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
                l1.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
                l2.topAnchor.constraint(equalTo: l1.bottomAnchor, constant: 4),
                l2.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
                l2.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
            ])
            row.addArrangedSubview(c)
        }
        p.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: p.trailingAnchor, constant: -24),
            row.topAnchor.constraint(equalTo: p.topAnchor, constant: y),
            row.heightAnchor.constraint(equalToConstant: 70),
        ]); y += 90

        // Active sandbox selector
        add(makeLabel("Active Sandbox", size: 15, bold: true), to: p, x: 24, y: y); y += 28
        let sbPopup = NSPopUpButton()
        sbPopup.translatesAutoresizingMaskIntoConstraints = false; sbPopup.removeAllItems()
        if sandboxes.isEmpty {
            sbPopup.addItem(withTitle: "No sandboxes \u{2014} run 'nemoclaw onboard'")
        } else {
            for sb in sandboxes { sbPopup.addItem(withTitle: sb.name + (sb.isDefault ? " \u{2605}" : "")) }
        }
        sbPopup.target = self; sbPopup.action = #selector(actSandboxChanged(_:))
        add(sbPopup, to: p, x: 24, y: y)
        sbPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true; y += 40

        // Services
        add(makeLabel("Services", size: 15, bold: true), to: p, x: 24, y: y); y += 28
        for svc in services {
            let r = hStack(8)
            r.addArrangedSubview(statusDot(svc.running))
            r.addArrangedSubview(makeLabel(svc.name))
            r.addArrangedSubview(makeLabel(svc.running ? "PID \(svc.pid)" : "Stopped", size: 11, color: kTextSecondary))
            add(r, to: p, x: 28, y: y); y += 26
        }; y += 12

        // Actions
        add(makeLabel("Quick Actions", size: 15, bold: true), to: p, x: 24, y: y); y += 28
        let btns = hStack(12)
        btns.addArrangedSubview(makeButton("Open Dashboard", action: #selector(actOpenDashboard), target: self))
        btns.addArrangedSubview(makeButton("Open Terminal", action: #selector(actOpenTerminal), target: self))
        btns.addArrangedSubview(makeButton("OpenShell TUI", action: #selector(actOpenTUI), target: self))
        btns.addArrangedSubview(makeButton("Refresh", action: #selector(actRefresh), target: self))
        add(btns, to: p, x: 24, y: y); y += 50

        // Credentials summary
        add(makeLabel("Credentials", size: 15, bold: true), to: p, x: 24, y: y); y += 28
        for c in credentials {
            let r = hStack(8)
            r.addArrangedSubview(statusDot(c.hasValue))
            r.addArrangedSubview(makeLabel(c.label))
            r.addArrangedSubview(makeLabel(c.hasValue ? "Configured" : "Missing", size: 11,
                                           color: c.hasValue ? kNvidiaGreen : kAccentRed))
            add(r, to: p, x: 28, y: y); y += 24
        }; y += 20
        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y).isActive = true
    }

    // ─────────────────────────────────────────
    // MARK: Sandboxes (Onboard Wizard)
    // ─────────────────────────────────────────

    func buildSandboxes(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Sandboxes", size: 22, bold: true), to: p, x: 24, y: y); y += 42

        // ── Onboard Wizard Card ──
        let wizard = makeCard(); p.addSubview(wizard)
        pin(wizard, in: p, top: y, hInset: 24)

        let wTitle = makeLabel("Create New Sandbox", size: 16, color: kNvidiaGreen, bold: true)
        wizard.addSubview(wTitle)

        // Name
        let nameL = makeLabel("Name:", size: 13)
        let nameField = NSTextField(); nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "my-assistant"; nameField.controlSize = .regular

        // Model
        let modelL = makeLabel("Model:", size: 13)
        let modelP = NSPopUpButton(); modelP.translatesAutoresizingMaskIntoConstraints = false
        modelP.addItems(withTitles: [
            "nvidia/nemotron-3-super-120b-a12b",
            "nvidia/nemotron-3-nano-30b-a3b",
            "nvidia/llama-3.1-nemotron-70b-instruct",
            "nvidia/llama-3.3-nemotron-super-49b-v1",
            "meta/llama-3.1-8b-instruct",
        ])

        // Provider
        let provL = makeLabel("Provider:", size: 13)
        let provP = NSPopUpButton(); provP.translatesAutoresizingMaskIntoConstraints = false
        provP.addItems(withTitles: ["cloud (NVIDIA API)", "ollama (Local)", "vllm (Local)", "nim (NIM Container)"])

        // GPU
        let gpuC = NSButton(checkboxWithTitle: "Enable GPU", target: nil, action: nil)
        gpuC.translatesAutoresizingMaskIntoConstraints = false; gpuC.contentTintColor = kNvidiaGreen
        if gpuInfo?.nimCapable == true { gpuC.state = .on }

        // Policy preset checkboxes
        let polL = makeLabel("Policies:", size: 13)
        let polStack = NSStackView(); polStack.orientation = .horizontal; polStack.spacing = 10
        polStack.translatesAutoresizingMaskIntoConstraints = false
        let defaultPolicies = ["npm", "pypi", "telegram", "docker"]
        for preset in policyPresets.prefix(6) {
            let cb = NSButton(checkboxWithTitle: preset.name, target: nil, action: nil)
            cb.state = defaultPolicies.contains(preset.name) ? .on : .off
            cb.contentTintColor = kNvidiaGreen
            polStack.addArrangedSubview(cb)
        }

        // Buttons
        let createBtn = makeButton("Run Onboard Wizard", action: #selector(actOnboardWizard), target: self)
        let quickBtn = makeButton("Quick Create (Non-Interactive)", action: #selector(actQuickCreate), target: self)

        for v in [nameL, nameField, modelL, modelP, provL, provP, gpuC, polL, polStack, createBtn, quickBtn] as [NSView] {
            wizard.addSubview(v)
        }

        let wPad: CGFloat = 16
        NSLayoutConstraint.activate([
            wTitle.topAnchor.constraint(equalTo: wizard.topAnchor, constant: 14),
            wTitle.leadingAnchor.constraint(equalTo: wizard.leadingAnchor, constant: wPad),
            nameL.topAnchor.constraint(equalTo: wTitle.bottomAnchor, constant: 16),
            nameL.leadingAnchor.constraint(equalTo: wizard.leadingAnchor, constant: wPad),
            nameL.widthAnchor.constraint(equalToConstant: 70),
            nameField.centerYAnchor.constraint(equalTo: nameL.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameL.trailingAnchor, constant: 4),
            nameField.widthAnchor.constraint(equalToConstant: 220),
            modelL.topAnchor.constraint(equalTo: nameL.bottomAnchor, constant: 12),
            modelL.leadingAnchor.constraint(equalTo: wizard.leadingAnchor, constant: wPad),
            modelL.widthAnchor.constraint(equalToConstant: 70),
            modelP.centerYAnchor.constraint(equalTo: modelL.centerYAnchor),
            modelP.leadingAnchor.constraint(equalTo: modelL.trailingAnchor, constant: 4),
            modelP.widthAnchor.constraint(equalToConstant: 380),
            provL.topAnchor.constraint(equalTo: modelL.bottomAnchor, constant: 12),
            provL.leadingAnchor.constraint(equalTo: wizard.leadingAnchor, constant: wPad),
            provL.widthAnchor.constraint(equalToConstant: 70),
            provP.centerYAnchor.constraint(equalTo: provL.centerYAnchor),
            provP.leadingAnchor.constraint(equalTo: provL.trailingAnchor, constant: 4),
            provP.widthAnchor.constraint(equalToConstant: 220),
            gpuC.topAnchor.constraint(equalTo: provL.bottomAnchor, constant: 12),
            gpuC.leadingAnchor.constraint(equalTo: wizard.leadingAnchor, constant: wPad),
            polL.topAnchor.constraint(equalTo: gpuC.bottomAnchor, constant: 12),
            polL.leadingAnchor.constraint(equalTo: wizard.leadingAnchor, constant: wPad),
            polStack.centerYAnchor.constraint(equalTo: polL.centerYAnchor),
            polStack.leadingAnchor.constraint(equalTo: polL.trailingAnchor, constant: 4),
            createBtn.topAnchor.constraint(equalTo: polL.bottomAnchor, constant: 16),
            createBtn.leadingAnchor.constraint(equalTo: wizard.leadingAnchor, constant: wPad),
            quickBtn.centerYAnchor.constraint(equalTo: createBtn.centerYAnchor),
            quickBtn.leadingAnchor.constraint(equalTo: createBtn.trailingAnchor, constant: 12),
            quickBtn.bottomAnchor.constraint(equalTo: wizard.bottomAnchor, constant: -14),
        ])
        y += 260

        // ── Existing Sandboxes ──
        if sandboxes.isEmpty {
            add(makeLabel("No sandboxes yet. Use the wizard above or run 'nemoclaw onboard'.",
                          size: 13, color: kTextSecondary), to: p, x: 24, y: y); y += 40
        }
        for (idx, sb) in sandboxes.enumerated() {
            let card = makeCard(); p.addSubview(card)
            pin(card, in: p, top: y, hInset: 24)

            let nm = makeLabel(sb.name + (sb.isDefault ? "  \u{2605} default" : ""), size: 15, color: kNvidiaGreen, bold: true)
            let ml = makeLabel("Model: \(sb.model)", size: 12, color: kTextSecondary)
            let pl = makeLabel("Provider: \(sb.provider)  |  GPU: \(sb.gpuEnabled ? "Yes" : "No")", size: 12, color: kTextSecondary)
            let po = makeLabel("Policies: \(sb.policies.isEmpty ? "none" : sb.policies.joined(separator: ", "))",
                               size: 12, color: kTextSecondary)

            let conn = makeButton("Connect", action: #selector(actConnect(_:)), target: self); conn.tag = idx
            let stat = makeButton("Status", action: #selector(actSbStatus(_:)), target: self); stat.tag = idx
            let del = makeButton("Delete", action: #selector(actDeleteSandbox(_:)), target: self); del.tag = idx
            del.contentTintColor = kAccentRed

            for v in [nm, ml, pl, po, conn, stat, del] as [NSView] { card.addSubview(v) }
            NSLayoutConstraint.activate([
                nm.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                nm.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                ml.topAnchor.constraint(equalTo: nm.bottomAnchor, constant: 6),
                ml.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                pl.topAnchor.constraint(equalTo: ml.bottomAnchor, constant: 4),
                pl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                po.topAnchor.constraint(equalTo: pl.bottomAnchor, constant: 4),
                po.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                po.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
                conn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                conn.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                stat.trailingAnchor.constraint(equalTo: conn.leadingAnchor, constant: -8),
                stat.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                del.trailingAnchor.constraint(equalTo: stat.leadingAnchor, constant: -8),
                del.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            ])
            y += 120
        }
        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y + 20).isActive = true
    }

    // ─────────────────────────────────────────
    // MARK: Inference
    // ─────────────────────────────────────────

    func buildInference(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Inference & GPU", size: 22, bold: true), to: p, x: 24, y: y); y += 42

        let card = makeCard(); p.addSubview(card); pin(card, in: p, top: y, hInset: 24)
        let chipLbl = makeLabel("GPU: \(gpuInfo?.chipName ?? "...")", size: 15, color: kNvidiaGreen, bold: true)
        let vramLbl = makeLabel("Memory: \(gpuInfo?.vram ?? "...")", size: 13, color: kTextSecondary)
        let nimLbl  = makeLabel("NIM Capable: \(gpuInfo?.nimCapable == true ? "Yes" : "No (cloud inference only)")",
                                size: 13, color: gpuInfo?.nimCapable == true ? kNvidiaGreen : kAccentYellow)
        for v in [chipLbl, vramLbl, nimLbl] { card.addSubview(v) }
        NSLayoutConstraint.activate([
            chipLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            chipLbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            vramLbl.topAnchor.constraint(equalTo: chipLbl.bottomAnchor, constant: 6),
            vramLbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            nimLbl.topAnchor.constraint(equalTo: vramLbl.bottomAnchor, constant: 4),
            nimLbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            nimLbl.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ]); y += 100

        // Provider selector
        add(makeLabel("Inference Provider", size: 15, bold: true), to: p, x: 24, y: y); y += 28
        let providerPopup = NSPopUpButton()
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.addItems(withTitles: ["NVIDIA API (Cloud)", "Ollama (Local)", "vLLM (Local)", "NIM Container (Local GPU)"])
        providerPopup.target = self; providerPopup.action = #selector(actProviderChanged(_:))
        add(providerPopup, to: p, x: 24, y: y)
        providerPopup.widthAnchor.constraint(equalToConstant: 350).isActive = true; y += 40

        // Model selector
        let models: [(String, String)] = [
            ("nvidia/nemotron-3-super-120b-a12b", "40 GB"),
            ("nvidia/nemotron-3-nano-30b-a3b", "8 GB"),
            ("nvidia/llama-3.1-nemotron-70b-instruct", "80 GB"),
            ("nvidia/llama-3.3-nemotron-super-49b-v1", "24 GB"),
            ("meta/llama-3.1-8b-instruct", "16 GB"),
        ]
        add(makeLabel("Select Model", size: 15, bold: true), to: p, x: 24, y: y); y += 28
        let modelPopup = NSPopUpButton()
        modelPopup.translatesAutoresizingMaskIntoConstraints = false
        for (name, vram) in models { modelPopup.addItem(withTitle: "\(name)  (\(vram) VRAM)") }
        modelPopup.target = self; modelPopup.action = #selector(actModelChanged(_:))
        add(modelPopup, to: p, x: 24, y: y)
        modelPopup.widthAnchor.constraint(equalToConstant: 500).isActive = true; y += 40

        let applyBtn = makeButton("Apply to Active Sandbox", action: #selector(actApplyInference), target: self)
        add(applyBtn, to: p, x: 24, y: y); y += 50

        // Backend status
        add(makeLabel("Local Inference Backends", size: 15, bold: true), to: p, x: 24, y: y); y += 28
        for (nm, cmd) in [("Ollama", "curl -sf http://localhost:11434/api/tags 2>/dev/null | head -c1"),
                          ("vLLM", "curl -sf http://localhost:8000/health 2>/dev/null | head -c1")] {
            let r = hStack(8)
            let running = !shell(cmd).isEmpty
            r.addArrangedSubview(statusDot(running))
            r.addArrangedSubview(makeLabel(nm, size: 13))
            r.addArrangedSubview(makeLabel(running ? "Running" : "Not detected", size: 11, color: kTextSecondary))
            add(r, to: p, x: 28, y: y); y += 24
        }
        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y + 20).isActive = true
    }

    // ─────────────────────────────────────────
    // MARK: Policies (Interactive Toggles)
    // ─────────────────────────────────────────

    func buildPolicies(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Network Policies", size: 22, bold: true), to: p, x: 24, y: y); y += 42

        // Target sandbox selector
        add(makeLabel("Target Sandbox:", size: 13, color: kTextSecondary), to: p, x: 24, y: y)
        let sbPopup = NSPopUpButton(); sbPopup.translatesAutoresizingMaskIntoConstraints = false
        sbPopup.removeAllItems()
        if sandboxes.isEmpty { sbPopup.addItem(withTitle: "(no sandboxes)") }
        else { for sb in sandboxes { sbPopup.addItem(withTitle: sb.name) } }
        add(sbPopup, to: p, x: 140, y: y)
        sbPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true; y += 36

        add(makeLabel("Toggle presets to control sandbox egress. Changes apply immediately.", size: 12, color: kTextSecondary),
            to: p, x: 24, y: y); y += 28

        let icons: [String: String] = [
            "telegram": "paperplane.fill", "discord": "bubble.left.and.bubble.right.fill",
            "slack": "number", "npm": "shippingbox", "pypi": "terminal.fill",
            "docker": "cube.box.fill", "huggingface": "face.smiling", "jira": "list.bullet.rectangle",
            "outlook": "envelope.fill",
        ]

        let descriptions: [String: String] = [
            "telegram": "api.telegram.org \u{2014} Bot API GET/POST",
            "discord": "discord.com, gateway.discord.gg \u{2014} Bot + WebSocket",
            "slack": "slack.com, api.slack.com, hooks.slack.com",
            "npm": "registry.npmjs.org, registry.yarnpkg.com",
            "pypi": "pypi.org, files.pythonhosted.org, conda.anaconda.org",
            "docker": "Docker Hub, nvcr.io, authn.nvidia.com",
            "huggingface": "huggingface.co, cdn-lfs, api-inference",
            "jira": "*.atlassian.net, JIRA API",
            "outlook": "*.office365.com, Outlook REST API",
        ]

        for (idx, preset) in policyPresets.enumerated() {
            let card = makeCard(); p.addSubview(card)
            pin(card, in: p, top: y, hInset: 24)
            card.heightAnchor.constraint(equalToConstant: 56).isActive = true

            let toggle = NSSwitch()
            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.state = (policyChecks[preset.name] == true) ? .on : .off
            toggle.target = self; toggle.action = #selector(actPolicyToggle(_:))
            toggle.tag = idx

            let r = hStack(10)
            if let iv = sfImage(icons[preset.name] ?? "network", size: 16) { r.addArrangedSubview(iv) }
            r.addArrangedSubview(makeLabel(preset.name.capitalized, size: 14, bold: true))

            let desc = makeLabel(descriptions[preset.name] ?? preset.file, size: 11, color: kTextSecondary)

            for v in [toggle, desc] as [NSView] { card.addSubview(v) }
            card.addSubview(r)
            NSLayoutConstraint.activate([
                toggle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                toggle.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                r.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 12),
                r.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: -8),
                desc.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 14),
                desc.topAnchor.constraint(equalTo: r.bottomAnchor, constant: 2),
            ])
            y += 64
        }

        // Apply all
        y += 8
        let applyBtn = makeButton("Apply All Policies to Sandbox", action: #selector(actApplyPolicies), target: self)
        add(applyBtn, to: p, x: 24, y: y); y += 40

        // Suggested presets
        let suggestBtn = makeButton("Auto-Detect Suggested Presets", action: #selector(actSuggestPolicies), target: self)
        add(suggestBtn, to: p, x: 24, y: y); y += 40

        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y + 20).isActive = true
    }

    // ─────────────────────────────────────────
    // MARK: Bridges
    // ─────────────────────────────────────────

    func buildBridges(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Messaging Bridges", size: 22, bold: true), to: p, x: 24, y: y); y += 42

        let bridges: [(String, String, String)] = [
            ("Telegram", "TELEGRAM_BOT_TOKEN",
             "Long-poll bot \u{2192} SSH \u{2192} sandbox agent \u{2192} reply. /start, /reset commands."),
            ("Discord", "DISCORD_BOT_TOKEN",
             "Bot token passed into sandbox via env. Upstream PR #601."),
            ("Slack", "SLACK_BOT_TOKEN",
             "Bot token passed into sandbox via env. Upstream PR #601."),
        ]
        for (name, tokenKey, desc) in bridges {
            let card = makeCard(); p.addSubview(card)
            pin(card, in: p, top: y, hInset: 24)

            let hasCred = credentials.first(where: { $0.key == tokenKey })?.hasValue ?? false
            let svc = services.first(where: { $0.name.lowercased().contains(name.lowercased()) })
            let running = svc?.running == true

            let nm = makeLabel(name, size: 16, color: kNvidiaGreen, bold: true)
            let badge = makeBadge(running ? "Running" : (hasCred ? "Ready" : "No Token"),
                                  color: running ? kNvidiaGreen : (hasCred ? kAccentYellow : kAccentRed))
            let dl = makeLabel(desc, size: 12, color: kTextSecondary); dl.preferredMaxLayoutWidth = 500

            for v in [nm, badge, dl] as [NSView] { card.addSubview(v) }
            NSLayoutConstraint.activate([
                nm.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                nm.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                badge.centerYAnchor.constraint(equalTo: nm.centerYAnchor),
                badge.leadingAnchor.constraint(equalTo: nm.trailingAnchor, constant: 10),
                dl.topAnchor.constraint(equalTo: nm.bottomAnchor, constant: 8),
                dl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                dl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                dl.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            ])

            if name == "Telegram" {
                let btn = makeButton(running ? "Stop" : "Start", action: #selector(actToggleTelegram), target: self)
                card.addSubview(btn)
                btn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16).isActive = true
                btn.topAnchor.constraint(equalTo: card.topAnchor, constant: 12).isActive = true
            }
            y += 90
        }

        // Cloudflare tunnel
        let tcard = makeCard(); p.addSubview(tcard); pin(tcard, in: p, top: y, hInset: 24)
        let tsvc = services.first(where: { $0.name.lowercased().contains("tunnel") || $0.name.lowercased().contains("cloud") })
        let trun = tsvc?.running == true
        let tn = makeLabel("Cloudflare Tunnel", size: 16, color: kNvidiaGreen, bold: true)
        let tb = makeBadge(trun ? "Running" : "Stopped", color: trun ? kNvidiaGreen : kAccentRed)
        let td = makeLabel("Provides a public HTTPS URL for remote access.", size: 12, color: kTextSecondary)
        for v in [tn, tb, td] as [NSView] { tcard.addSubview(v) }
        NSLayoutConstraint.activate([
            tn.topAnchor.constraint(equalTo: tcard.topAnchor, constant: 14),
            tn.leadingAnchor.constraint(equalTo: tcard.leadingAnchor, constant: 16),
            tb.centerYAnchor.constraint(equalTo: tn.centerYAnchor),
            tb.leadingAnchor.constraint(equalTo: tn.trailingAnchor, constant: 10),
            td.topAnchor.constraint(equalTo: tn.bottomAnchor, constant: 8),
            td.leadingAnchor.constraint(equalTo: tcard.leadingAnchor, constant: 16),
            td.bottomAnchor.constraint(equalTo: tcard.bottomAnchor, constant: -14),
        ]); y += 80
        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y + 20).isActive = true
    }

    // ─────────────────────────────────────────
    // MARK: Telegram Remote Control
    // ─────────────────────────────────────────

    func buildTelegramRemote(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Telegram Remote Control", size: 22, bold: true), to: p, x: 24, y: y); y += 36
        add(makeLabel("Send commands to NemoClaw from your phone via Telegram bot.", size: 13, color: kTextSecondary),
            to: p, x: 24, y: y); y += 32

        // Status card
        let hasTgToken = credentials.first(where: { $0.key == "TELEGRAM_BOT_TOKEN" })?.hasValue ?? false
        let tgRunning = services.first(where: { $0.name.lowercased().contains("telegram") })?.running ?? false

        let statusCard = makeCard(); p.addSubview(statusCard)
        pin(statusCard, in: p, top: y, hInset: 24)
        let stL = makeLabel("Bridge Status", size: 14, bold: true)
        let stBadge = makeBadge(tgRunning ? "Running" : (hasTgToken ? "Ready" : "No Token"),
                                color: tgRunning ? kNvidiaGreen : (hasTgToken ? kAccentYellow : kAccentRed))
        let stBtn = makeButton(tgRunning ? "Stop Bridge" : "Start Bridge", action: #selector(actToggleTelegram), target: self)
        for v in [stL, stBadge, stBtn] as [NSView] { statusCard.addSubview(v) }
        NSLayoutConstraint.activate([
            stL.centerYAnchor.constraint(equalTo: statusCard.centerYAnchor),
            stL.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            stBadge.centerYAnchor.constraint(equalTo: statusCard.centerYAnchor),
            stBadge.leadingAnchor.constraint(equalTo: stL.trailingAnchor, constant: 10),
            stBtn.centerYAnchor.constraint(equalTo: statusCard.centerYAnchor),
            stBtn.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            statusCard.heightAnchor.constraint(equalToConstant: 50),
        ]); y += 64

        // Available commands card
        let cmdCard = makeCard(); p.addSubview(cmdCard)
        pin(cmdCard, in: p, top: y, hInset: 24)
        let cmdTitle = makeLabel("Available Commands", size: 14, bold: true)
        cmdCard.addSubview(cmdTitle)
        cmdTitle.topAnchor.constraint(equalTo: cmdCard.topAnchor, constant: 14).isActive = true
        cmdTitle.leadingAnchor.constraint(equalTo: cmdCard.leadingAnchor, constant: 16).isActive = true

        let commands: [(String, String)] = [
            ("/start", "Subscribe to bot, show welcome message"),
            ("/reset", "Clear conversation history / session"),
            ("/status", "Get sandbox & service health (custom)"),
            ("/logs", "Fetch recent sandbox log tail (custom)"),
            ("/restart", "Restart the active sandbox (custom)"),
            ("Any text", "Forwarded to OpenClaw agent via SSH \u{2192} reply"),
        ]
        var cy: CGFloat = 38
        for (cmd, desc) in commands {
            let cL = makeLabel(cmd, size: 12, color: kNvidiaGreen, bold: true, mono: true)
            let dL = makeLabel(desc, size: 12, color: kTextSecondary)
            cmdCard.addSubview(cL); cmdCard.addSubview(dL)
            cL.topAnchor.constraint(equalTo: cmdCard.topAnchor, constant: cy).isActive = true
            cL.leadingAnchor.constraint(equalTo: cmdCard.leadingAnchor, constant: 16).isActive = true
            cL.widthAnchor.constraint(equalToConstant: 100).isActive = true
            dL.centerYAnchor.constraint(equalTo: cL.centerYAnchor).isActive = true
            dL.leadingAnchor.constraint(equalTo: cL.trailingAnchor, constant: 10).isActive = true
            cy += 24
        }
        cmdCard.heightAnchor.constraint(equalToConstant: cy + 14).isActive = true
        y += cy + 28

        // Configuration card
        let cfgCard = makeCard(); p.addSubview(cfgCard)
        pin(cfgCard, in: p, top: y, hInset: 24)
        let cfgTitle = makeLabel("Configuration", size: 14, bold: true)
        cfgCard.addSubview(cfgTitle)
        cfgTitle.topAnchor.constraint(equalTo: cfgCard.topAnchor, constant: 14).isActive = true
        cfgTitle.leadingAnchor.constraint(equalTo: cfgCard.leadingAnchor, constant: 16).isActive = true

        // Allowed chat IDs
        let chatIdL = makeLabel("Restrict to Chat IDs:", size: 13)
        let chatIdField = NSTextField()
        chatIdField.translatesAutoresizingMaskIntoConstraints = false
        chatIdField.placeholderString = "Comma-separated (blank = allow all)"
        chatIdField.controlSize = .regular
        let existingIds = shell("cat '\(kNemoDir)/telegram-allowed-chats' 2>/dev/null")
        if !existingIds.isEmpty { chatIdField.stringValue = existingIds }

        let saveBtn = makeButton("Save Chat ID Restriction", action: #selector(actSaveTelegramChatIds), target: self)
        let testBtn = makeButton("Send Test Message", action: #selector(actTestTelegram), target: self)

        for v in [chatIdL, chatIdField, saveBtn, testBtn] as [NSView] { cfgCard.addSubview(v) }
        NSLayoutConstraint.activate([
            chatIdL.topAnchor.constraint(equalTo: cfgTitle.bottomAnchor, constant: 14),
            chatIdL.leadingAnchor.constraint(equalTo: cfgCard.leadingAnchor, constant: 16),
            chatIdField.centerYAnchor.constraint(equalTo: chatIdL.centerYAnchor),
            chatIdField.leadingAnchor.constraint(equalTo: chatIdL.trailingAnchor, constant: 8),
            chatIdField.widthAnchor.constraint(equalToConstant: 300),
            saveBtn.topAnchor.constraint(equalTo: chatIdL.bottomAnchor, constant: 12),
            saveBtn.leadingAnchor.constraint(equalTo: cfgCard.leadingAnchor, constant: 16),
            testBtn.centerYAnchor.constraint(equalTo: saveBtn.centerYAnchor),
            testBtn.leadingAnchor.constraint(equalTo: saveBtn.trailingAnchor, constant: 12),
            testBtn.bottomAnchor.constraint(equalTo: cfgCard.bottomAnchor, constant: -14),
        ]); y += 120

        // Live bridge log
        add(makeLabel("Bridge Log (live)", size: 14, bold: true), to: p, x: 24, y: y); y += 24
        let tv = NSTextView()
        tv.isEditable = false
        tv.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        tv.textColor = kNvidiaGreen
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.translatesAutoresizingMaskIntoConstraints = false

        let ls = NSScrollView()
        ls.translatesAutoresizingMaskIntoConstraints = false
        ls.hasVerticalScroller = true; ls.documentView = tv
        ls.wantsLayer = true; ls.layer?.cornerRadius = 8; ls.drawsBackground = false
        p.addSubview(ls)
        NSLayoutConstraint.activate([
            ls.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: 24),
            ls.trailingAnchor.constraint(equalTo: p.trailingAnchor, constant: -24),
            ls.topAnchor.constraint(equalTo: p.topAnchor, constant: y),
            ls.heightAnchor.constraint(equalToConstant: 200),
            tv.widthAnchor.constraint(equalTo: ls.widthAnchor),
        ])

        // Stream telegram log
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? "nemoclaw"
        let logFile = "/tmp/nemoclaw-services-\(sb)/telegram-bridge.log"
        logTextView = tv
        shellAsync("tail -50 '\(logFile)' 2>/dev/null") { text in
            tv.string = text.isEmpty ? "No Telegram bridge log yet. Start the bridge to see output." : text
            tv.scrollToEndOfDocument(nil)
        }
        logStreamTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            shellAsync("tail -5 '\(logFile)' 2>/dev/null") { text in
                guard let tv = self?.logTextView, !text.isEmpty else { return }
                let existing = tv.string
                let newLines = text.components(separatedBy: "\n").filter { !$0.isEmpty && !existing.contains($0) }
                if !newLines.isEmpty {
                    tv.string += "\n" + newLines.joined(separator: "\n")
                    tv.scrollToEndOfDocument(nil)
                }
            }
        }
        y += 220
        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y + 20).isActive = true
    }

    // ─────────────────────────────────────────
    // MARK: Upstream Sync
    // ─────────────────────────────────────────

    func buildSync(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Upstream Sync", size: 22, bold: true), to: p, x: 24, y: y); y += 42

        let card = makeCard(); p.addSubview(card); pin(card, in: p, top: y, hInset: 24)

        let statusColor: NSColor = syncBehind < 0 ? kAccentRed : (syncBehind == 0 ? kNvidiaGreen : kAccentYellow)
        let statusText = syncBehind < 0 ? "Unable to check" :
            (syncBehind == 0 ? "Up to date with NVIDIA/NemoClaw" : "\(syncBehind) commit\(syncBehind == 1 ? "" : "s") behind")

        let sl = makeLabel(statusText, size: 16, color: statusColor, bold: true)
        var checkStr = "Never checked"
        if let d = syncChecked {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            checkStr = "Last checked: \(f.string(from: d))"
        }
        let cl = makeLabel(checkStr, size: 12, color: kTextSecondary)
        let al = makeLabel("Auto-sync runs every 6 hours via GitHub Actions", size: 12, color: kTextSecondary)
        let fb = makeButton("Fetch Now", action: #selector(actFetch), target: self)
        let tb = makeButton("Trigger GitHub Action", action: #selector(actTriggerSync), target: self)

        for v in [sl, cl, al, fb, tb] as [NSView] { card.addSubview(v) }
        NSLayoutConstraint.activate([
            sl.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            sl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cl.topAnchor.constraint(equalTo: sl.bottomAnchor, constant: 6),
            cl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            al.topAnchor.constraint(equalTo: cl.bottomAnchor, constant: 4),
            al.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            fb.topAnchor.constraint(equalTo: al.bottomAnchor, constant: 12),
            fb.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            tb.topAnchor.constraint(equalTo: al.bottomAnchor, constant: 12),
            tb.leadingAnchor.constraint(equalTo: fb.trailingAnchor, constant: 12),
            tb.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ]); y += 160

        // Recent commits
        add(makeLabel("Recent Upstream Commits", size: 15, bold: true), to: p, x: 24, y: y); y += 28
        shellAsync("cd '\(repoPath)' && git log upstream/main --oneline -10 2>/dev/null") { [weak self] raw in
            guard let _ = self else { return }
            var ly = y
            for line in raw.components(separatedBy: "\n").filter({ !$0.isEmpty }).prefix(10) {
                let l = makeLabel(line, size: 11, color: kTextSecondary, mono: true)
                self?.add(l, to: p, x: 28, y: ly); ly += 18
            }
            p.heightAnchor.constraint(greaterThanOrEqualToConstant: ly + 20).isActive = true
        }
        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y + 220).isActive = true
    }

    // ─────────────────────────────────────────
    // MARK: Credentials
    // ─────────────────────────────────────────

    func buildCredentials(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Credentials", size: 22, bold: true), to: p, x: 24, y: y); y += 42
        add(makeLabel("Stored in ~/.nemoclaw/credentials.json (mode 600). Env vars take precedence.",
                       size: 12, color: kTextSecondary), to: p, x: 24, y: y); y += 30

        for (idx, cred) in credentials.enumerated() {
            let card = makeCard(); p.addSubview(card)
            pin(card, in: p, top: y, hInset: 24)
            card.heightAnchor.constraint(equalToConstant: 52).isActive = true

            let d = statusDot(cred.hasValue)
            let n = makeLabel(cred.label, size: 14, bold: true)
            let h = makeLabel(cred.hint, size: 11, color: kTextSecondary)
            let s = makeLabel(cred.hasValue ? "\u{2713} Configured" : "\u{2717} Missing",
                              size: 12, color: cred.hasValue ? kNvidiaGreen : kAccentRed)
            let eb = makeButton("Set\u{2026}", action: #selector(actEditCred(_:)), target: self); eb.tag = idx
            for v in [d, n, h, s, eb] as [NSView] { card.addSubview(v) }
            NSLayoutConstraint.activate([
                d.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                d.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                n.leadingAnchor.constraint(equalTo: d.trailingAnchor, constant: 10),
                n.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                h.leadingAnchor.constraint(equalTo: d.trailingAnchor, constant: 10),
                h.topAnchor.constraint(equalTo: n.bottomAnchor, constant: 2),
                eb.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                eb.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                s.trailingAnchor.constraint(equalTo: eb.leadingAnchor, constant: -10),
                s.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            ]); y += 60
        }

        let vb = makeButton("Verify All Credentials", action: #selector(actVerifyCreds), target: self)
        add(vb, to: p, x: 24, y: y)
        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y + 60).isActive = true
    }

    // ─────────────────────────────────────────
    // MARK: Logs (Live Streaming)
    // ─────────────────────────────────────────

    func buildLogs(_ p: NSView) {
        var y: CGFloat = 20
        add(makeLabel("Logs", size: 22, bold: true), to: p, x: 24, y: y); y += 42

        // Source selector
        add(makeLabel("Source:", size: 13, color: kTextSecondary), to: p, x: 24, y: y)
        let srcPopup = NSPopUpButton()
        srcPopup.translatesAutoresizingMaskIntoConstraints = false
        srcPopup.addItems(withTitles: ["Sandbox Logs", "Telegram Bridge", "Cloudflare Tunnel"])
        srcPopup.target = self; srcPopup.action = #selector(actSwitchLogSource(_:))
        add(srcPopup, to: p, x: 80, y: y)
        srcPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true; y += 36

        let btns = hStack(10)
        btns.addArrangedSubview(makeButton("Clear", action: #selector(actClearLogs), target: self))
        btns.addArrangedSubview(makeButton("Open in Terminal", action: #selector(actSandboxLogs), target: self))
        btns.addArrangedSubview(makeButton("Export Debug Bundle", action: #selector(actDebugBundle), target: self))
        add(btns, to: p, x: 24, y: y); y += 36

        // Live indicator
        let liveStack = hStack(6)
        liveStack.addArrangedSubview(statusDot(true))
        liveStack.addArrangedSubview(makeLabel("Live \u{2014} auto-refreshes every 3s", size: 11, color: kNvidiaGreen))
        add(liveStack, to: p, x: 24, y: y); y += 24

        let tv = NSTextView()
        tv.isEditable = false
        tv.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        tv.textColor = kNvidiaGreen
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.translatesAutoresizingMaskIntoConstraints = false

        let ls = NSScrollView()
        ls.translatesAutoresizingMaskIntoConstraints = false
        ls.hasVerticalScroller = true; ls.documentView = tv
        ls.wantsLayer = true; ls.layer?.cornerRadius = 8; ls.drawsBackground = false
        p.addSubview(ls)
        NSLayoutConstraint.activate([
            ls.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: 24),
            ls.trailingAnchor.constraint(equalTo: p.trailingAnchor, constant: -24),
            ls.topAnchor.constraint(equalTo: p.topAnchor, constant: y),
            ls.heightAnchor.constraint(equalToConstant: 420),
            tv.widthAnchor.constraint(equalTo: ls.widthAnchor),
        ])

        logTextView = tv
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? sandboxes.first?.name ?? "nemoclaw"
        loadLogSource(source: "sandbox", sandbox: sb, into: tv)

        // Auto-refresh timer
        logStreamTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshLogStream()
        }

        p.heightAnchor.constraint(greaterThanOrEqualToConstant: y + 450).isActive = true
    }

    var currentLogSource = "sandbox"
    var currentLogCmd = ""

    func loadLogSource(source: String, sandbox: String, into tv: NSTextView) {
        currentLogSource = source
        switch source {
        case "telegram":
            currentLogCmd = "tail -100 '/tmp/nemoclaw-services-\(sandbox)/telegram-bridge.log' 2>/dev/null"
        case "tunnel":
            currentLogCmd = "tail -100 '/tmp/nemoclaw-services-\(sandbox)/cloudflared.log' 2>/dev/null"
        default:
            currentLogCmd = "openshell sandbox logs \(sandbox) 2>/dev/null | tail -100"
        }
        shellAsync(currentLogCmd) { text in
            tv.string = text.isEmpty ? "No logs available. Start the service to see output." : text
            tv.scrollToEndOfDocument(nil)
        }
    }

    func refreshLogStream() {
        guard let tv = logTextView, !currentLogCmd.isEmpty else { return }
        let tailCmd = currentLogCmd.replacingOccurrences(of: "tail -100", with: "tail -10")
        shellAsync(tailCmd) { text in
            guard !text.isEmpty else { return }
            let existing = tv.string
            let newLines = text.components(separatedBy: "\n").filter { !$0.isEmpty && !existing.hasSuffix($0) }
            if !newLines.isEmpty {
                tv.string += "\n" + newLines.joined(separator: "\n")
                tv.scrollToEndOfDocument(nil)
            }
        }
    }

    // ═══════════════════════════════════════════
    // MARK: - Actions
    // ═══════════════════════════════════════════

    @objc func actOpenDashboard() { NSWorkspace.shared.open(URL(string: kDashboardURL)!) }

    @objc func actOpenTerminal() {
        runAppleScript("tell application \"Terminal\"\nactivate\ndo script \"cd '\(repoPath)'\"\nend tell")
    }

    @objc func actOpenTUI() {
        runAppleScript("tell application \"Terminal\"\nactivate\ndo script \"openshell term\"\nend tell")
    }

    @objc func actRefresh() { refreshAll() }

    @objc func actConnect(_ sender: NSButton) {
        guard sender.tag < sandboxes.count else { return }
        let name = sandboxes[sender.tag].name
        runAppleScript("tell application \"Terminal\"\nactivate\ndo script \"nemoclaw \(name) connect\"\nend tell")
    }

    @objc func actSbStatus(_ sender: NSButton) {
        guard sender.tag < sandboxes.count else { return }
        let name = sandboxes[sender.tag].name
        data.sandboxStatus(name) { status in
            self.alert("Sandbox: \(name)", "Status: \(status)")
        }
    }

    @objc func actDeleteSandbox(_ sender: NSButton) {
        guard sender.tag < sandboxes.count else { return }
        let name = sandboxes[sender.tag].name
        let a = NSAlert()
        a.messageText = "Delete Sandbox?"
        a.informativeText = "This will destroy sandbox '\(name)' and all its data. This cannot be undone."
        a.alertStyle = .critical
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        shellAsync("openshell sandbox delete \(name) 2>&1") { [weak self] result in
            self?.alert("Sandbox Deleted", result.isEmpty ? "Sandbox '\(name)' has been deleted." : result)
            self?.refreshAll()
        }
    }

    @objc func actToggleTelegram() {
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? "nemoclaw"
        let tg = services.first(where: { $0.name.lowercased().contains("telegram") })
        if tg?.running == true {
            if let pidStr = tg?.pid, let pid = Int32(pidStr) {
                kill(pid, SIGTERM)
            }
        } else {
            let script = "cd '\(repoPath)' && SANDBOX_NAME=\(sb) node scripts/telegram-bridge.js"
            let pidDir = "/tmp/nemoclaw-services-\(sb)"
            shellAsync("mkdir -p '\(pidDir)' && nohup bash -c '\(script)' > '\(pidDir)/telegram-bridge.log' 2>&1 & echo $!") { pid in
                if !pid.isEmpty {
                    try? pid.write(toFile: "\(pidDir)/telegram-bridge.pid", atomically: true, encoding: .utf8)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshAll() }
    }

    @objc func actFetch() {
        data.checkUpstreamSync(repoPath: repoPath) { [weak self] n, lbl in
            self?.syncBehind = n; self?.syncLabel = lbl; self?.syncChecked = Date(); self?.render()
        }
    }

    @objc func actTriggerSync() {
        shellAsync("gh workflow run sync-upstream --repo Gunnarguy/NemoClaw 2>&1") { result in
            self.alert("Sync Workflow",
                       result.isEmpty ? "Triggered successfully. Check GitHub Actions for status." : result)
        }
    }

    @objc func actVerifyCreds() {
        shellAsync("node '\(repoPath)/scripts/verify-credentials.js' 2>&1") { result in
            self.alert("Credential Verification", result.isEmpty ? "All credentials verified." : result)
        }
    }

    @objc func actSandboxLogs() {
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? "nemoclaw"
        runAppleScript("tell application \"Terminal\"\nactivate\ndo script \"nemoclaw \(sb) logs --follow\"\nend tell")
    }

    @objc func actTelegramLogs() {
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? "nemoclaw"
        let f = "/tmp/nemoclaw-services-\(sb)/telegram-bridge.log"
        if FileManager.default.fileExists(atPath: f) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) }
        else { alert("No Log File", "Telegram bridge log not found. Start the bridge first.") }
    }

    @objc func actTunnelLogs() {
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? "nemoclaw"
        let f = "/tmp/nemoclaw-services-\(sb)/cloudflared.log"
        if FileManager.default.fileExists(atPath: f) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) }
        else { alert("No Log File", "Cloudflared log not found. Start the tunnel first.") }
    }

    @objc func actDebugBundle() {
        let out = "\(kHome)/Desktop/nemoclaw-debug-\(Int(Date().timeIntervalSince1970)).tar.gz"
        shellAsync("nemoclaw debug --output '\(out)' 2>&1") { result in
            self.alert("Debug Bundle", result.isEmpty ? "Exported to \(out)" : result)
        }
    }

    @objc func actSandboxChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem < sandboxes.count else { return }
        let sb = sandboxes[sender.indexOfSelectedItem]
        data.serviceStatuses(sandbox: sb.name) { [weak self] s in self?.services = s; self?.render() }
    }

    @objc func actProviderChanged(_ sender: NSPopUpButton) { }
    @objc func actModelChanged(_ sender: NSPopUpButton) { }

    @objc func actApplyInference() {
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? "nemoclaw"
        let providers = ["cloud", "ollama", "vllm", "nim"]
        let models = [
            "nvidia/nemotron-3-super-120b-a12b",
            "nvidia/nemotron-3-nano-30b-a3b",
            "nvidia/llama-3.1-nemotron-70b-instruct",
            "nvidia/llama-3.3-nemotron-super-49b-v1",
            "meta/llama-3.1-8b-instruct",
        ]
        // Find selected provider/model from the rendered popups (search contentBox)
        var provIdx = 0; var modIdx = 0
        func findPopups(in view: NSView) {
            for sub in view.subviews {
                if let popup = sub as? NSPopUpButton {
                    if popup.numberOfItems == 4 { provIdx = popup.indexOfSelectedItem }
                    if popup.numberOfItems == 5 { modIdx = popup.indexOfSelectedItem }
                }
                findPopups(in: sub)
            }
        }
        findPopups(in: contentBox)
        let prov = provIdx < providers.count ? providers[provIdx] : "cloud"
        let model = modIdx < models.count ? models[modIdx] : models[0]
        let cmd = "cd '\(repoPath)' && NEMOCLAW_PROVIDER=\(prov) NEMOCLAW_MODEL=\(model) node -e \"const nim=require('./bin/lib/nim'); nim.setupInference('\(sb)','\(model)','\(prov)').catch(console.error)\" 2>&1"
        shellAsync(cmd, timeout: 30) { [weak self] result in
            self?.alert("Inference Configured", result.isEmpty ? "Provider: \(prov)\nModel: \(model)\nApplied to: \(sb)" : result)
            self?.refreshAll()
        }
    }

    // ── Policy Actions ──

    @objc func actPolicyToggle(_ sender: NSSwitch) {
        guard sender.tag < policyPresets.count else { return }
        let name = policyPresets[sender.tag].name
        policyChecks[name] = sender.state == .on
    }

    @objc func actApplyPolicies() {
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? "nemoclaw"
        let enabled = policyPresets.filter { policyChecks[$0.name] == true }.map { $0.name }
        if enabled.isEmpty {
            alert("No Policies", "Enable at least one policy preset to apply.")
            return
        }
        let presetList = enabled.joined(separator: ",")
        let cmd = "cd '\(repoPath)' && NEMOCLAW_POLICY_MODE=custom NEMOCLAW_POLICY_PRESETS=\(presetList) node -e \"const p=require('./bin/lib/policies'); p.setupPolicies('\(sb)').catch(console.error)\" 2>&1"
        shellAsync(cmd, timeout: 30) { [weak self] result in
            self?.alert("Policies Applied", result.isEmpty ? "Applied to \(sb): \(enabled.joined(separator: ", "))" : result)
            self?.refreshAll()
        }
    }

    @objc func actSuggestPolicies() {
        // Auto-detect: always npm + pypi, plus telegram/discord/slack if tokens exist
        var suggested = ["npm", "pypi"]
        if credentials.first(where: { $0.key == "TELEGRAM_BOT_TOKEN" })?.hasValue ?? false { suggested.append("telegram") }
        if credentials.first(where: { $0.key == "DISCORD_BOT_TOKEN" })?.hasValue ?? false { suggested.append("discord") }
        if credentials.first(where: { $0.key == "SLACK_BOT_TOKEN" })?.hasValue ?? false { suggested.append("slack") }
        for preset in policyPresets {
            policyChecks[preset.name] = suggested.contains(preset.name)
        }
        render()
        alert("Auto-Detected", "Suggested presets enabled: \(suggested.joined(separator: ", "))\n\nClick 'Apply All Policies' to apply them.")
    }

    // ── Onboard Actions ──

    @objc func actOnboardWizard() {
        runAppleScript("tell application \"Terminal\"\nactivate\ndo script \"cd '\(repoPath)' && nemoclaw onboard\"\nend tell")
    }

    @objc func actQuickCreate() {
        // Find the name field and popup values from the wizard card
        var name = ""; var model = ""; var provider = ""
        var policies: [String] = []
        func findFields(in view: NSView) {
            for sub in view.subviews {
                if let tf = sub as? NSTextField, tf.isEditable, tf.placeholderString == "my-assistant" {
                    name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let popup = sub as? NSPopUpButton {
                    let title = popup.titleOfSelectedItem ?? ""
                    if title.contains("nvidia/") || title.contains("meta/") { model = title }
                    if title.contains("cloud") || title.contains("ollama") || title.contains("vllm") || title.contains("nim") {
                        provider = title.components(separatedBy: " ").first ?? "cloud"
                    }
                }
                if let cb = sub as? NSButton, cb.bezelStyle == .regularSquare || cb.allowsMixedState == false {
                    if cb.state == .on && cb.title != "Enable GPU" && !cb.title.isEmpty {
                        policies.append(cb.title)
                    }
                }
                findFields(in: sub)
            }
        }
        findFields(in: contentBox)

        if name.isEmpty { name = "my-assistant" }
        if model.isEmpty { model = "nvidia/nemotron-3-nano-30b-a3b" }
        if provider.isEmpty { provider = "cloud" }
        let polMode = policies.isEmpty ? "suggested" : "custom"
        let polPresets = policies.joined(separator: ",")

        var envParts = [
            "NEMOCLAW_SANDBOX_NAME=\(name)",
            "NEMOCLAW_PROVIDER=\(provider)",
            "NEMOCLAW_MODEL=\(model)",
            "NEMOCLAW_POLICY_MODE=\(polMode)",
        ]
        if !polPresets.isEmpty { envParts.append("NEMOCLAW_POLICY_PRESETS=\(polPresets)") }

        let envStr = envParts.joined(separator: " ")
        runAppleScript("tell application \"Terminal\"\nactivate\ndo script \"cd '\(repoPath)' && \(envStr) nemoclaw onboard\"\nend tell")
    }

    // ── Credential Actions ──

    @objc func actEditCred(_ sender: NSButton) {
        guard sender.tag < credentials.count else { return }
        let cred = credentials[sender.tag]
        let a = NSAlert()
        a.messageText = "Set \(cred.label)"
        a.informativeText = cred.hint
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let tf = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.placeholderString = cred.hint
        a.accessoryView = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let val = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else { return }
        // Read existing, merge, write
        let path = "\(kNemoDir)/credentials.json"
        var existing: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            existing = json
        }
        existing[cred.key] = val
        if let jsonData = try? JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted) {
            try? FileManager.default.createDirectory(atPath: kNemoDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: jsonData)
            // Set file to mode 600
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        credentials = data.loadCredentials()
        render()
    }

    // ── Telegram Actions ──

    @objc func actSaveTelegramChatIds() {
        // Find the chat ID text field
        var chatIds = ""
        func findField(in view: NSView) {
            for sub in view.subviews {
                if let tf = sub as? NSTextField, tf.isEditable,
                   tf.placeholderString?.contains("Comma-separated") == true {
                    chatIds = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                findField(in: sub)
            }
        }
        findField(in: contentBox)
        let path = "\(kNemoDir)/telegram-allowed-chats"
        try? FileManager.default.createDirectory(atPath: kNemoDir, withIntermediateDirectories: true)
        try? chatIds.write(toFile: path, atomically: true, encoding: .utf8)
        alert("Saved", chatIds.isEmpty ? "Restriction cleared \u{2014} all chat IDs allowed." :
                "Restricted to: \(chatIds)\n\nRestart the bridge for changes to take effect.")
    }

    @objc func actTestTelegram() {
        let hasTgToken = credentials.first(where: { $0.key == "TELEGRAM_BOT_TOKEN" })?.hasValue ?? false
        guard hasTgToken else {
            alert("No Token", "Set TELEGRAM_BOT_TOKEN in Credentials first.")
            return
        }
        shellAsync("node -e \"const https=require('https'); const t=process.env.TELEGRAM_BOT_TOKEN||require('\(kNemoDir)/credentials.json').TELEGRAM_BOT_TOKEN; https.get('https://api.telegram.org/bot'+t+'/getMe', r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>console.log(d))})\" 2>&1") { result in
            self.alert("Telegram Bot Test", result.isEmpty ? "No response received." : result)
        }
    }

    // ── Log Actions ──

    @objc func actSwitchLogSource(_ sender: NSPopUpButton) {
        let sources = ["sandbox", "telegram", "tunnel"]
        let idx = sender.indexOfSelectedItem
        let source = idx < sources.count ? sources[idx] : "sandbox"
        let sb = sandboxes.first(where: { $0.isDefault })?.name ?? "nemoclaw"
        if let tv = logTextView { loadLogSource(source: source, sandbox: sb, into: tv) }
    }

    @objc func actClearLogs() {
        logTextView?.string = ""
    }

    // ── Helpers ─────────────────────────────

    func add(_ v: NSView, to p: NSView, x: CGFloat, y: CGFloat) {
        p.addSubview(v)
        v.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: x).isActive = true
        v.topAnchor.constraint(equalTo: p.topAnchor, constant: y).isActive = true
    }

    func pin(_ v: NSView, in p: NSView, top: CGFloat, hInset: CGFloat) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: hInset),
            v.trailingAnchor.constraint(equalTo: p.trailingAnchor, constant: -hInset),
            v.topAnchor.constraint(equalTo: p.topAnchor, constant: top),
        ])
    }

    func hStack(_ spacing: CGFloat) -> NSStackView {
        let s = NSStackView(); s.orientation = .horizontal; s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false; return s
    }

    func alert(_ title: String, _ body: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = body
        a.alertStyle = .informational; a.addButton(withTitle: "OK"); a.runModal()
    }

    func runAppleScript(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

// ═══════════════════════════════════════════
// MARK: - Sidebar DataSource / Delegate
// ═══════════════════════════════════════════

extension HubWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { HubSection.allCases.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let sec = HubSection.allCases[row]
        let cell = NSTableCellView()

        let stack = hStack(8)
        if let iv = sfImage(sec.icon, size: 14, color: row == sidebar.selectedRow ? kNvidiaGreen : kTextSecondary) {
            stack.addArrangedSubview(iv)
        }
        stack.addArrangedSubview(makeLabel(sec.rawValue, size: 13,
                                           color: row == sidebar.selectedRow ? kTextPrimary : kTextSecondary))
        cell.addSubview(stack)
        stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8).isActive = true
        stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        return cell
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < HubSection.allCases.count else { return }
        selected = HubSection.allCases[row]
        sidebar.reloadData()
        render()
    }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = NSTableRowView(); rv.isEmphasized = false; return rv
    }
}

// ═══════════════════════════════════════════
// MARK: - Menu Bar Status Item
// ═══════════════════════════════════════════

class StatusBarController: NSObject {
    var statusItem: NSStatusItem!
    var hubWC: HubWindowController?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            if let img = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "NemoClaw") {
                btn.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
                btn.contentTintColor = kNvidiaGreen
            }
        }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open NemoClaw Hub", action: #selector(show), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem.separator())
        let dashItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashItem.target = self
        menu.addItem(dashItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit NemoClaw Hub",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc func show() {
        if hubWC == nil { hubWC = HubWindowController() }
        hubWC?.showWindow(nil)
        hubWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDashboard() {
        NSWorkspace.shared.open(URL(string: kDashboardURL)!)
    }
}

// ═══════════════════════════════════════════
// MARK: - App Delegate
// ═══════════════════════════════════════════

class AppDelegate: NSObject, NSApplicationDelegate {
    let bar = StatusBarController()

    func applicationDidFinishLaunching(_ n: Notification) {
        HubNotificationManager.shared.setup()
        setupMainMenu()
        bar.setup()
        bar.show()
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        bar.show(); return true
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About NemoClaw Hub",
                                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                    keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit NemoClaw Hub",
                                    action: #selector(NSApplication.terminate(_:)),
                                    keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close Window",
                                       action: #selector(NSWindow.performClose(_:)),
                                       keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                       action: #selector(NSWindow.performMiniaturize(_:)),
                                       keyEquivalent: "m"))
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

// ═══════════════════════════════════════════
// MARK: - Main
// ═══════════════════════════════════════════

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
