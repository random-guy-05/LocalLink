import Foundation

enum CheckError: Error { case failed(String) }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError.failed(message) }
}

@main enum Regression {
    @MainActor static func main() async throws {
        // Regressions for the offline-vs-authentication issue observed during setup.
        try check(Reachability.classify(valid: true, running: true, peerOnline: false, routeResponded: false, hostResponded: false) == .offline, "Offline peers must not be described as missing installations.")
        try check(Reachability.classify(valid: true, running: true, peerOnline: true, routeResponded: true, hostResponded: false) == .hostMissing, "A reachable mini without Sunshine needs host setup.")
        try check(Reachability.classify(valid: true, running: false, peerOnline: nil, routeResponded: false, hostResponded: false) == .networkDisconnected, "A local VPN failure needs a different action.")
        try check(Reachability.classify(valid: true, running: true, peerOnline: false, routeResponded: false, hostResponded: true) == .ready, "A real endpoint reply must outrank stale offline state.")

        let samples = PingParser.parse("""
        pong from mini (198.51.100.10) via DERP(lax) in 44ms
        pong from mini (198.51.100.10) via 192.0.2.1:41641 in 18.25ms
        pong from mini (198.51.100.10) via peer-relay(test) in 0.2s
        ping timed out
        2026/10/22 no reply
        """)
        try check(samples.count == 3 && samples[0].route == .relay && samples[1].route == .direct && samples[2].route == .peerRelay, "Warm-up relays, direct paths, and peer relays must be distinguished.")
        try check(samples[2].milliseconds == 200 && samples[1].milliseconds == 18.25, "Seconds and fractional milliseconds must keep their units.")

        for host in ["--help", "user@mini", "https://mini", "mini;touch /tmp/example", "a..b", "bad:host", "-mini", "mini-"] {
            try check(!HostAddress.valid(host), "Reject unsafe or malformed host: \(host)")
        }
        try check(HostAddress.valid("198.51.100.10") && HostAddress.valid("mini.tailnet.ts.net"), "Support known IP and DNS hosts.")
        try check(HostAddress.url("fd7a:115c:a1e0::e29:6b44", port: 47989, path: "/serverinfo") != nil, "IPv6 hosts need correct URL brackets.")

        let legacy = Data("{\"host\":\"198.51.100.10\",\"resolution\":\"2560x1600\",\"fps\":60,\"bitrate\":30,\"codec\":\"auto\",\"fullscreen\":true,\"overlay\":false,\"application\":\"Desktop\"}".utf8)
        let migrated = try JSONDecoder().decode(StreamSettings.self, from: legacy)
        try check(migrated.bitrate == 30 && migrated.host == "198.51.100.10" && migrated.hardwareOnly && migrated.pacing == .smooth, "Keep existing user settings when adding new fields.")
        let broken = Data("{\"fps\":-8,\"bitrate\":-500,\"codec\":\"typo\",\"resolution\":\"bad\",\"application\":\"--help\"}".utf8)
        let repaired = try JSONDecoder().decode(StreamSettings.self, from: broken)
        try check(repaired.fps == 60 && repaired.bitrate == 5 && repaired.application == "Desktop", "Malformed preferences must not create invalid engine requests.")

        let literal = "literal $(never-execute) ; --help"
        let spacedPath = "/tmp/LocalLink Application Support/test.sock"
        let sshConfig = await Command.run("/usr/bin/ssh", ["-G", "-o", "ControlPath=\(LocalPaths.sshConfigValue(spacedPath))", "-o", "UserKnownHostsFile=\(LocalPaths.sshConfigValue(spacedPath + ".hosts"))", "example.invalid"], timeout: 3)
        try check(sshConfig.status == 0 && sshConfig.output.contains("controlpath \(spacedPath)"), "OpenSSH option values must preserve paths containing spaces.")
        let command = await Command.run("/usr/bin/printf", ["%s", literal], timeout: 2)
        try check(command.status == 0 && command.output == literal, "Subprocess inputs must stay literal argument values.")
        let started = Date()
        let timeout = await Command.run("/bin/sleep", ["10"], timeout: 0.15)
        try check(timeout.timedOut && Date().timeIntervalSince(started) < 3, "A timed-out command must finish promptly.")
        let flood = await Command.run("/usr/bin/yes", ["bounded capture"], timeout: 0.15)
        try check(flood.timedOut && flood.output.utf8.count <= 128_000, "Continuous subprocess output must stay bounded without deadlocking.")
        let owned = ViewerProcess()
        var rejectedOverlap = false
        let stopped: Bool = await withCheckedContinuation { continuation in
            do {
                try owned.start(executable: "/bin/sleep", arguments: ["10"], output: { _ in }, completion: { _, stopped in continuation.resume(returning: stopped) })
                do { try owned.start(executable: "/bin/sleep", arguments: ["10"], output: { _ in }, completion: { _, _ in }) }
                catch { rejectedOverlap = true }
                Task { @MainActor in try? await Task.sleep(nanoseconds: 150_000_000); owned.stop() }
            } catch { continuation.resume(returning: false) }
        }
        try check(stopped && rejectedOverlap && !owned.running, "Only one managed viewer may run, and disconnect must reap its process.")
        print("PASS: availability regressions, path parsing, unsafe host rejection, IPv6, preferences migration, literal arguments, timeouts, bounded capture, single viewer ownership, disconnect cleanup.")
    }
}
