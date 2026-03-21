// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// NemoClaw Status — macOS menu bar status item
// Monitors dashboard health and provides quick actions.

import Cocoa
import Foundation

// MARK: - Health Check

enum DashboardStatus: String {
    case connected = "Connected"
    case disconnected = "Disconnected"
    case checking = "Checking…"
}

func checkDashboard(url: String, completion: @escaping (Bool) -> Void) {
    guard let u = URL(string: url) else { completion(false); return }
    var req = URLRequest(url: u, timeoutInterval: 3)
    req.httpMethod = "HEAD"
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            completion(true)
        } else {
            completion(false)
        }
    }.resume()
}

func shellOutput(_ cmd: String, timeout: TimeInterval = 8) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", cmd]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    // Propagate PATH so openshell is findable
    var env = ProcessInfo.processInfo.environment
    let home = env["HOME"] ?? NSHomeDirectory()
    let localBin = "\(home)/.local/bin"
    let existing = env["PATH"] ?? "/usr/bin:/bin"
    env["PATH"] = "\(localBin):/opt/homebrew/bin:\(existing)"
    process.environment = env

    do {
        try process.run()
    } catch {
        return ""
    }

    let deadline = DispatchTime.now() + timeout
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        process.waitUntilExit()
        group.leave()
    }
    if group.wait(timeout: deadline) == .timedOut {
        process.terminate()
        return ""
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// MARK: - App Delegate

class StatusBarApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastStatus: DashboardStatus = .checking

    let dashboardURL = "http://127.0.0.1:18789"
    let pollInterval: TimeInterval = 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateIcon(.checking)
        buildMenu()

        // Initial check
        refreshStatus()

        // Periodic polling
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func updateIcon(_ status: DashboardStatus) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let color: NSColor
        switch status {
        case .connected:
            symbol = "checkmark.circle.fill"
            color = NSColor(red: 0.46, green: 0.73, blue: 0.0, alpha: 1.0) // NVIDIA green
        case .disconnected:
            symbol = "xmark.circle.fill"
            color = .systemRed
        case .checking:
            symbol = "arrow.triangle.2.circlepath"
            color = .secondaryLabelColor
        }

        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "NemoClaw \(status.rawValue)") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let tinted = img.withSymbolConfiguration(config)!
            button.image = tinted
            button.contentTintColor = color
        }

        button.toolTip = "NemoClaw: \(status.rawValue)"
        lastStatus = status
    }

    func refreshStatus() {
        checkDashboard(url: dashboardURL) { [weak self] ok in
            DispatchQueue.main.async {
                let newStatus: DashboardStatus = ok ? .connected : .disconnected
                let oldStatus = self?.lastStatus
                self?.updateIcon(newStatus)
                self?.buildMenu()

                // Notify on transitions
                if oldStatus == .disconnected && newStatus == .connected {
                    self?.sendNotification(title: "NemoClaw", body: "Dashboard is back online")
                } else if oldStatus == .connected && newStatus == .disconnected {
                    self?.sendNotification(title: "NemoClaw", body: "Dashboard went offline")
                }
            }
        }
    }

    func sendNotification(title: String, body: String) {
        let script = "display notification \"\(body)\" with title \"\(title)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    func buildMenu() {
        let menu = NSMenu()

        // Status header
        let statusLabel = NSMenuItem(title: "Status: \(lastStatus.rawValue)", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(NSMenuItem.separator())

        // Quick actions
        let openDashboard = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        openDashboard.target = self
        openDashboard.isEnabled = lastStatus == .connected
        menu.addItem(openDashboard)

        let recoverItem = NSMenuItem(title: "Recover Dashboard", action: #selector(recoverDashboard), keyEquivalent: "r")
        recoverItem.target = self
        menu.addItem(recoverItem)

        menu.addItem(NSMenuItem.separator())

        let logsItem = NSMenuItem(title: "View Logs…", action: #selector(openLogs), keyEquivalent: "l")
        logsItem.target = self
        menu.addItem(logsItem)

        let terminalItem = NSMenuItem(title: "Open Terminal", action: #selector(openTerminal), keyEquivalent: "t")
        terminalItem.target = self
        menu.addItem(terminalItem)

        menu.addItem(NSMenuItem.separator())

        // Gateway status (async — just show last known)
        let gwItem = NSMenuItem(title: "Gateway Info…", action: #selector(showGatewayInfo), keyEquivalent: "g")
        gwItem.target = self
        menu.addItem(gwItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit NemoClaw Status", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc func openDashboard() {
        NSWorkspace.shared.open(URL(string: dashboardURL)!)
    }

    @objc func recoverDashboard() {
        updateIcon(.checking)
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let home = NSHomeDirectory()
            let repoDir = shellOutput("cat '\(home)/.nemoclaw/repo-path' 2>/dev/null") .isEmpty
                ? "\(home)/Documents/GitHub/NemoClaw"
                : shellOutput("cat '\(home)/.nemoclaw/repo-path' 2>/dev/null")

            // Try the launcher's recovery mode
            _ = shellOutput("bash '\(repoDir)/scripts/launch-macos.sh' --recover-ui </dev/null >/dev/null 2>&1 &")

            // Wait a moment then refresh
            Thread.sleep(forTimeInterval: 5)
            DispatchQueue.main.async {
                self.refreshStatus()
            }
        }
    }

    @objc func openLogs() {
        let logDir = "\(NSHomeDirectory())/.nemoclaw/logs"
        let agentLog = "\(logDir)/ui-agent.log"
        let forwardLog = "\(logDir)/ui-forward.log"

        // Open whichever exist in Console.app or just the directory
        let fm = FileManager.default
        if fm.fileExists(atPath: agentLog) {
            NSWorkspace.shared.open(URL(fileURLWithPath: agentLog))
        } else if fm.fileExists(atPath: forwardLog) {
            NSWorkspace.shared.open(URL(fileURLWithPath: forwardLog))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: logDir))
        }
    }

    @objc func openTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "openshell term"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    @objc func showGatewayInfo() {
        DispatchQueue.global().async {
            let raw = shellOutput("openshell status 2>/dev/null | perl -pe 's/\\e\\[[0-9;]*[A-Za-z]//g'")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "NemoClaw Gateway"
                alert.informativeText = raw.isEmpty ? "Unable to query gateway status." : raw
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc func refreshNow() {
        updateIcon(.checking)
        refreshStatus()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No Dock icon
let delegate = StatusBarApp()
app.delegate = delegate
app.run()
