// unlocker.swift - Vanish Unlocker (macOS, native, zero dependencies)
//
// One app, two unlocks:
//   [Open Vanish (Mac)]   - starts an embedded entitlement server on
//                           127.0.0.1:8787 serving tier "paid", launches the
//                           installed Vanish with VANISH_API_URL set, and
//                           stops the server when Vanish quits.
//   [Unlock iPhone App]   - patches the stock Vanish.ipa (embedded five-word
//                           patcher) and drives the installed desktop app's
//                           sideloader helper over its JSON-lines protocol:
//                           Apple ID login (+2FA) -> device -> sign ->
//                           install over the existing app (data preserved).
//
// Requires: the Vanish desktop app installed at /Applications/Vanish.app
// (it carries the stock mobile IPA and the sideloader helper).

import Foundation
import Network
import SwiftUI

// MARK: - constants

let helperPath = "/Applications/Vanish.app/Contents/Resources/sideloader/VanishSideloader"
let stockIpaPath = "/Applications/Vanish.app/Contents/Resources/vanish-ipa/Vanish.ipa"
let vanishBinary = "/Applications/Vanish.app/Contents/MacOS/Vanish"
let vanishBundle = "/Applications/Vanish.app"
let dataDir = NSHomeDirectory() + "/Library/Application Support/Vanish/sideloader"
let serverPort: UInt16 = 8787

let patchSites: [(UInt64, UInt32, UInt32)] = [
    // (vaddr, expected original word, replacement) - Vanish 3.3.0 arm64
    (0x100189874, 0x94000636, 0xD503201F), // bl enforceSpoofDenial (r3)   -> NOP
    (0x10018A2FC, 0x94000394, 0xD503201F), // bl enforceSpoofDenial (r5)   -> NOP
    (0x100189F84, 0x94000390, 0xD503201F), // bl scheduleRewardExpiryCheck -> NOP
    (0x10018AA0C, 0x940000EE, 0xD503201F), // bl scheduleRewardExpiryCheck -> NOP
    (0x10010C3F4, 0x942354C2, 0x5280003B), // bl release -> movz w27,#1 (pro=true)
]
let textBase: UInt64 = 0x100000000
let patchedBinRel = "Payload/StikDebug.app/StikDebug"

// MARK: - entitlement server

final class EntitlementServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "unlocker.server")

    func start() -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: serverPort)!) else { return false }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            let c = Conn(conn: conn)
            conn.start(queue: self?.queue ?? DispatchQueue(label: "unlocker.conn"))
            c.readLoop(queue: self?.queue ?? DispatchQueue(label: "unlocker.conn"))
        }
        l.start(queue: queue)
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // one connection = one buffered request
    private final class Conn {
        let conn: NWConnection
        var buf = Data()
        init(conn: NWConnection) { self.conn = conn }

        func readLoop(queue: DispatchQueue) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let d = data, !d.isEmpty { self.buf.append(d) }
                let s = String(data: self.buf, encoding: .utf8) ?? ""
                if s.contains("\r\n\r\n") || complete || error != nil {
                    self.respond()
                } else {
                    self.readLoop(queue: queue)
                }
            }
        }

        private func respond() {
            let req = String(data: buf, encoding: .utf8) ?? ""
            let body: String
            let status: String
            switch true {
            case req.contains("entitlement-get"):
                body = """
                {"entitlement":{"tier":"paid","trial_expires_at":null,"email":"paid@localhost","billing_portal_available":true,"extension_available":false}}
                """
                status = "200 OK"
            case req.contains("trial-bootstrap"), req.contains("trial-start"),
                 req.contains("trial-extend"), req.contains("checkout-status"):
                body = """
                {"ok":true,"completed":false}
                """
                status = "200 OK"
            case req.contains("pricing-get"):
                body = """
                {"ok":true,"prices":{}}
                """
                status = "200 OK"
            case req.contains("track-event"), req.contains("dev-reset-machine"):
                body = """
                {"ok":true}
                """
                status = "202 Accepted"
            default:
                body = """
                {"ok":false,"error":"not implemented by unlocker"}
                """
                status = "404 Not Found"
            }
            let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            let resp = (head + body).data(using: .utf8)!
            conn.send(content: resp, completion: .contentProcessed { _ in self.conn.cancel() })
        }
    }
}

// MARK: - process helpers

func runProcess(_ path: String, _ args: [String], currentDirectory: String? = nil) -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd = currentDirectory { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try? p.run()
    p.waitUntilExit()
    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, o, e)
}

// MARK: - IPA patcher (embedded five-word patch)

enum PatchError: LocalizedError {
    case notFound(String)
    case mismatch(UInt64, UInt32, UInt32)
    case zip(Int32, String)
    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "Not found: \(p)"
        case .mismatch(let v, let want, let got):
            return String(format: "Patch site 0x%X mismatch: expected 0x%08X, found 0x%08X - this IPA is not Vanish 3.3.0 arm64; refusing to guess.", v, want, got)
        case .zip(let code, let why): return "zip tool failed (\(code)): \(why)"
        }
    }
}

func patchIpa(src: String, out: String) throws {
    guard FileManager.default.fileExists(atPath: src) else { throw PatchError.notFound(src) }
    let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("vanish-unlock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: work) }

    let (code, _, err) = runProcess("/usr/bin/unzip", ["-q", "-o", src, "-d", work])
    guard code == 0 else { throw PatchError.zip(code, err) }

    let bin = work + "/" + patchedBinRel
    // App-Management protection: an unsigned binary cannot content-write a
    // provenance-marked executable (the stock IPA extracted from the
    // developer's signed app carries com.apple.provenance). The dance:
    // plain-copy the binary, strip its extended attributes, patch the copy,
    // restore the exec mode, rename over the original.
    let patchedCopy = bin + ".patched"
    let (cc, _, ce) = runProcess("/bin/cp", [bin, patchedCopy])
    guard cc == 0 else { throw PatchError.zip(cc, ce) }
    let (xc, _, xe) = runProcess("/usr/bin/xattr", ["-c", patchedCopy])
    guard xc == 0 else { throw PatchError.zip(xc, xe) }

    NSLog("[patch] before open-for-write %@", patchedCopy)
    let fh = try FileHandle(forUpdating: URL(fileURLWithPath: patchedCopy))
    NSLog("[patch] open-for-write OK")
    defer { try? fh.close() }
    for (vaddr, want, repl) in patchSites {
        let off = Int64(vaddr - textBase)
        try fh.seek(toOffset: UInt64(off))
        let raw = try fh.read(upToCount: 4) ?? Data()
        guard raw.count == 4 else { throw PatchError.mismatch(vaddr, want, 0) }
        let got = raw.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard got == want else { throw PatchError.mismatch(vaddr, want, got) }
        var r = repl.littleEndian
        let d = Data(bytes: &r, count: 4)
        try fh.seek(toOffset: UInt64(off))
        try fh.write(contentsOf: d)
    }
    try fh.close()
    let (pc, _, pe) = runProcess("/bin/chmod", ["755", patchedCopy])
    guard pc == 0 else { throw PatchError.zip(pc, pe) }
    let (mc, _, me) = runProcess("/bin/mv", ["-f", patchedCopy, bin])
    guard mc == 0 else { throw PatchError.zip(mc, me) }

    if FileManager.default.fileExists(atPath: out) { try FileManager.default.removeItem(atPath: out) }
    // zip -j keeps the payload layout: zip the Payload tree from the work dir
    NSLog("[patch] before zip")
    let (zc, _, ze) = runProcess("/usr/bin/zip", ["-q", "-r", "-y", out, "Payload"], currentDirectory: work)
    NSLog("[patch] zip exit %d", zc)
    guard zc == 0 else { throw PatchError.zip(zc, ze) }

    // verify: reread the patched words from the output IPA
    let vwork = (NSTemporaryDirectory() as NSString).appendingPathComponent("vanish-verify-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: vwork, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: vwork) }
    let (vc, _, ve) = runProcess("/usr/bin/unzip", ["-q", "-o", out, "-d", vwork])
    guard vc == 0 else { throw PatchError.zip(vc, ve) }
    NSLog("[patch] before verify-open %@", vwork + "/" + patchedBinRel)
    let vfh = try FileHandle(forReadingFrom: URL(fileURLWithPath: vwork + "/" + patchedBinRel))
    NSLog("[patch] verify-open OK")
    defer { try? vfh.close() }
    for (vaddr, _, repl) in patchSites {
        try vfh.seek(toOffset: UInt64(vaddr - textBase))
        let raw = try vfh.read(upToCount: 4) ?? Data()
        let got = raw.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard got == repl else { throw PatchError.mismatch(vaddr, repl, got) }
    }
}

// MARK: - sideloader driver (JSON-lines)

final class SideloadDriver: ObservableObject {
    enum Stage: Equatable {
        case idle, patching, patchDone
        case login, awaiting2FA, installing
        case done, failed(String)
    }
    @Published var stage: Stage = .idle
    @Published var status: String = ""
    @Published var installPercent: Int = 0
    @Published var needs2FA = false

    private var proc: Process?
    private var stdin: FileHandle?
    private var nextId = 1
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private var loginPassword: String = ""
    private var loggedIn = false
    private let queue = DispatchQueue(label: "unlocker.driver")

    func start(email: String, password: String, ipaPath: String) {
        loginPassword = password
        Task.detached { [weak self] in
            await self?.run(email: email, ipaPath: ipaPath)
        }
    }

    func submit2FA(_ code: String) {
        needs2FA = false
        _ = send("two_factor_code", ["code": code]) { [weak self] (resp: [String: Any]) in
            if resp["ok"] as? Bool == true {
                self?.stage = .installing
                self?.install(self?.ipaPathFromLastRun ?? "")
            } else {
                self?.needs2FA = true
                self?.status = "2FA failed: \(resp["error"] ?? "unknown") - try again"
            }
        }
    }

    private var ipaPathFromLastRun = ""

    private func run(email: String, ipaPath: String) async {
        ipaPathFromLastRun = ipaPath
        await MainActor.run { self.stage = .patching; self.status = "Patching the IPA..." }
        do {
            let out = (NSTemporaryDirectory() as NSString).appendingPathComponent("Vanish-patched-\(UUID().uuidString).ipa")
            try patchIpa(src: ipaPath, out: out)
            ipaPathFromLastRun = out
            await MainActor.run { self.stage = .patchDone; self.status = "IPA patched. Starting the sideloader..." }
        } catch {
            await MainActor.run { self.stage = .failed(error.localizedDescription) }
            return
        }
        spawnHelper()
        await MainActor.run { self.stage = .login; self.status = "Signing in to Apple ID..." }
        _ = send("login", ["email": email, "password": loginPassword]) { [weak self] resp in
            guard let self = self else { return }
            if resp["ok"] as? Bool == true {
                self.loggedIn = true
                DispatchQueue.main.async { self.stage = .installing }
                self.install(self.ipaPathFromLastRun)
            } else if let err = resp["error"] as? [String: Any], (err["type"] as? String) == "TwoFactorRequired" {
                DispatchQueue.main.async { self.needs2FA = true; self.status = "Enter the 2FA code" }
            } else {
                DispatchQueue.main.async { let em = (resp["error"] as? [String: Any])?["message"] as? String ?? "\(resp)"; self.stage = .failed("Login failed: \(em)") }
            }
        }
    }

    private func install(_ ipa: String) {
        _ = send("list_devices", [:]) { [weak self] resp in
            guard let self = self else { return }
            guard resp["ok"] as? Bool == true, let devs = resp["data"] as? [[String: Any]], let d = devs.first,
                  let udid = d["udid"] as? String else {
                DispatchQueue.main.async { self.stage = .failed("No device found - connect the iPhone over USB and unlock it.") }
                return
            }
            _ = self.send("select_device", ["udid": udid]) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async { self.status = "Signing and installing (this can take a few minutes)..." }
                _ = self.send("install_sidestore", ["path": ipa], timeout: 1200) { [weak self] resp in
                    guard let self = self else { return }
                    if resp["ok"] as? Bool == true {
                        DispatchQueue.main.async { self.stage = .done; self.status = "Installed. The iPhone app is unlocked." }
                        self.stopHelper()
                    } else {
                        DispatchQueue.main.async { self.stage = .failed("Install failed: \(resp["error"] ?? resp)") }
                        self.stopHelper()
                    }
                }
            }
        }
    }

    // MARK: low-level JSON-lines plumbing

    private func spawnHelper() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.arguments = ["--data-dir", dataDir, "--temp-dir", NSTemporaryDirectory()]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = Pipe()
        try? p.run()
        proc = p
        stdin = p.standardInput as? FileHandle
        var buf = ""
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty, let self = self else { return }
            buf += String(data: d, encoding: .utf8) ?? ""
            while let nl = buf.firstIndex(of: "\n") {
                let line = String(buf[..<nl]).trimmingCharacters(in: .whitespaces)
                buf = String(buf[buf.index(after: nl)...])
                if !line.isEmpty { self.handleLine(line) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { NSLog("[helper] %@", String(data: d, encoding: .utf8) ?? "") }
        }
    }

    private func handleLine(_ line: String) {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        if let event = obj["event"] as? String {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch event {
                case "log": self.status = (obj["message"] as? String) ?? self.status
                case "step": self.status = "step \(obj["id"] ?? "?"): \(obj["state"] ?? "")"
                case "install_progress":
                    self.installPercent = (obj["percent"] as? Int) ?? self.installPercent
                case "2fa_required":
                    self.needs2FA = true
                    self.status = "Enter the 2FA code"
                case "helper_lost":
                    if case .installing = self.stage { self.stage = .failed("sideloader helper lost") }
                default: break
                }
            }
            // max-certs: auto-choose to revoke nothing, surface it
            if event == "max_certs_reached" {
                _ = send("max_certs_response", ["serials": [String]()]) { [weak self] _ in
                    DispatchQueue.main.async { self?.status = "Apple ID at cert limit - use the desktop app to remove a certificate, then retry." }
                }
            }
            return
        }
        if let id = obj["id"] as? Int, let cb = pending.removeValue(forKey: id) {
            cb(obj)
        }
    }

    @discardableResult
    private func send(_ cmd: String, _ args: [String: Any], timeout: Double = 600,
                      _ cb: @escaping ([String: Any]) -> Void) -> Int {
        let id = nextId
        nextId += 1
        let payload = NSMutableDictionary(dictionary: ["id": id, "cmd": cmd])
        for (k, v) in args { payload[k] = v }
        let line = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)! + "\n"
        pending[id] = cb
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let self = self, self.pending.removeValue(forKey: id) != nil {
                DispatchQueue.main.async { self.stage = .failed("\(cmd) timed out") }
            }
        }
        stdin?.write(line.data(using: .utf8)!)
        return id
    }

    private func stopHelper() {
        try? stdin?.close()
        proc?.terminate()
        proc = nil
    }
}

// MARK: - the mac launcher (server + Vanish with VANISH_API_URL)

struct MacLauncher {
    let server = EntitlementServer()

    func open() -> String {
        guard FileManager.default.fileExists(atPath: vanishBinary) else {
            return "Vanish is not installed at /Applications/Vanish.app - install it first."
        }
        guard server.start() else {
            return "Could not start the entitlement server on port \(serverPort) (already running?)."
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: vanishBinary)
        p.environment = ProcessInfo.processInfo.environment
        p.environment?["VANISH_API_URL"] = "http://127.0.0.1:\(serverPort)"
        try? p.run()
        DispatchQueue.global().async { [weak server] in
            p.waitUntilExit()
            server?.stop()
        }
        return "Vanish launched - tier: paid. The server stops when Vanish quits."
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var driver = SideloadDriver()
    @State private var macStatus = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code2fa = ""
    @State private var showPhone = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("Vanish Unlocker").font(.title.bold())

            if !showPhone {
                VStack(spacing: 16) {
                    Button {
                        macStatus = MacLauncher().open()
                    } label: {
                        Label("Open Vanish (Mac) - paid", systemImage: "desktopcomputer")
                            .font(.headline).frame(maxWidth: 320)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    if !macStatus.isEmpty {
                        Text(macStatus).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Divider().frame(width: 240)
                    Button("Unlock the iPhone app...") { withAnimation { showPhone = true } }
                        .controlSize(.large)
                }
            } else {
                phonePane
            }
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder private var phonePane: some View {
        switch driver.stage {
        case .idle, .patching, .patchDone, .login:
            VStack(spacing: 14) {
                Text("Unlock the iPhone app").font(.headline)
                TextField("Apple ID email", text: $email).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                SecureField("Apple ID password", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Button {
                    driver.start(email: email, password: password, ipaPath: stockIpaPath)
                } label: {
                    Label("Patch + install to iPhone", systemImage: "iphone")
                        .font(.headline).frame(maxWidth: 300)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty)
                if !driver.status.isEmpty { Text(driver.status).font(.footnote).foregroundStyle(.secondary) }
            }
        case .awaiting2FA, .installing:
            VStack(spacing: 14) {
                if driver.needs2FA {
                    Text("Enter the 2FA code").font(.headline)
                    HStack {
                        TextField("6-digit code", text: $code2fa).textFieldStyle(.roundedBorder).frame(width: 140)
                        Button("Send") { driver.submit2FA(code2fa); code2fa = "" }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                    Text(driver.status.isEmpty ? "Working..." : driver.status).font(.footnote).foregroundStyle(.secondary)
                    if driver.installPercent > 0 { Text("Installing: \(driver.installPercent)%") }
                }
            }
        case .done:
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("The iPhone app is unlocked").font(.headline)
                Text("Spoofing, routes, schedule and Saved Places run with no deny path and no auto-stop.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Done") { driver.stage = .idle; showPhone = false }
            }
        case .failed(let why):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                Text("Stopped").font(.headline)
                Text(why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Back") { driver.stage = .idle }
            }
        }
    }
}

@main
struct UnlockerApp: App {
    init() {
        if ProcessInfo.processInfo.environment["UNLOCKER_PATCH_TEST"] != nil {
            DispatchQueue.global().async {
                let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("autotest-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
                let (c, o, e) = runProcess("/usr/bin/unzip", ["-q", "-o", stockIpaPath, "-d", work])
                let bin = work + "/" + patchedBinRel
                NSLog("[autotest] unzip exit=%d out=%@ err=%@ exists=%d bin=%@", c, o, e,
                      FileManager.default.fileExists(atPath: bin) ? 1 : 0, bin)
                // diagnostics: plain cp, xattr -c, then open; also open the Info.plist
                let copy = work + "/copy.bin"
                let (cp1, _, _) = runProcess("/bin/cp", [bin, copy])
                let (xc, _, xe) = runProcess("/usr/bin/xattr", ["-c", copy])
                var diag = ""
                do {
                    let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: copy))
                    try fh.close()
                    diag += " open-copy(after xattr -c):OK"
                } catch { diag += " open-copy(after xattr -c):FAIL(\(error.localizedDescription))" }
                let plist = work + "/Payload/StikDebug.app/Info.plist"
                do {
                    let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: plist))
                    try fh.close()
                    diag += " open-plist:OK"
                } catch { diag += " open-plist:FAIL(\(error.localizedDescription))" }
                NSLog("[autotest] cp=%d xattr=%d(%@)%@", cp1, xc, xe, diag)
                do {
                    let out = (NSTemporaryDirectory() as NSString).appendingPathComponent("autotest-patched.ipa")
                    try patchIpa(src: stockIpaPath, out: out)
                    NSLog("[autotest] PATCH PASS - wrote %@", out)
                    exit(0)
                } catch {
                    NSLog("[autotest] PATCH FAIL - %@", error.localizedDescription)
                    exit(1)
                }
            }
        }
        if ProcessInfo.processInfo.environment["UNLOCKER_HEADLESS_TEST"] != nil {
            let s = EntitlementServer()
            guard s.start() else { NSLog("[autotest] server failed to start"); exit(1) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                let probe = """
                curl -s -X POST http://127.0.0.1:8787/entitlement-get -H 'Content-Type: application/json' -d '{}'
                """
                let (code, out, _) = runProcess("/bin/sh", ["-c", probe + " ; curl -s -X POST http://127.0.0.1:8787/trial-bootstrap -d '{}' ; curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8787/track-event -d '{}'"])
                NSLog("[autotest] exit=\(code) out=\(out)")
                let ok = out.contains("\"tier\":\"paid\"") && out.contains("\"ok\":true") && out.contains("202")
                s.stop()
                NSLog(ok ? "[autotest] PASS" : "[autotest] FAIL")
                exit(ok ? 0 : 1)
            }
        }
    }
    var body: some Scene {
        WindowGroup("Vanish Unlocker") { ContentView() }
            .windowResizability(.contentSize)
    }
}
