import Foundation

// MARK: - models

/// One frequency band of a card. A dual-frequency card has two of these.
struct CardTrack: Codable, Hashable, Identifiable {
    enum Band: String, Codable { case lf, hf }
    var id = UUID()
    var band: Band
    var family: String          // em410x | mifare_classic | encrypted | unknown
    var ident: String?          // EM410x ID or MIFARE UID
    var cloneable: Bool
    var dumpfile: String?       // MIFARE dump path

    var familyLabel: String {
        switch family {
        case "em410x": return "EM410x"
        case "hid_prox": return "HID Prox"
        case "mifare_classic": return "MIFARE Classic"
        case "encrypted": return "Encrypted"
        default: return "Unknown"
        }
    }
    var bandLabel: String { band == .lf ? "LF 125 kHz" : "HF 13.56 MHz" }
}

/// A saved card in the library.
struct SavedCard: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var created = Date()
    var notes: String = ""
    var tracks: [CardTrack]

    var isDual: Bool { tracks.count > 1 }
    var summary: String {
        tracks.map { $0.familyLabel }.joined(separator: " + ")
    }
}

struct OpResult {
    var ok: Bool
    var match: Bool?
    var message: String
    var raw: String
}

// MARK: - pm3 engine
//
// Nothing here touches USB. Every call launches the `pm3` CLI as a subprocess
// and reads its text output, exactly like typing `pm3 -c "hf search"`.

enum PM3 {

    static let encryptedMarkers = [
        "DESFire", "MIFARE Plus", "SEOS", "iCLASS SE",
        "iCLASS Elite", "PicoPass SE", "NTAG 424",
    ]
    static let noCardMarkers = ["No known", "No data", "No tag", "no answer", "Valid ISO"]

    static var dumpDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("pm3kit/dumps", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: subprocess

    /// Seconds to let a pm3 command run before giving up. With no Proxmark3
    /// attached the CLI prints "Waiting for Proxmark3 to appear..." and never
    /// exits, so every call needs a deadline.
    static let quickCommandTimeout: TimeInterval = 90
    static let longCommandTimeout: TimeInterval = 900

    /// Every descendant of `root`, deepest last.
    static func descendantPIDs(of root: pid_t) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "pid=,ppid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for line in (String(data: out, encoding: .utf8) ?? "").split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2,
                  let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
            childrenByParent[parent, default: []].append(pid)
        }

        var found: [pid_t] = []
        var pending = childrenByParent[root] ?? []
        while let next = pending.popLast() {
            found.append(next)
            pending.append(contentsOf: childrenByParent[next] ?? [])
        }
        return found
    }

    /// `pm3` is a bash wrapper that launches `proxmark3` as a child, so
    /// signalling only the wrapper would orphan the client holding the USB
    /// port. Signal the whole tree, then force what is left.
    static func terminateProcessTree(root: pid_t) {
        let ownPID = getpid()
        let tree = (descendantPIDs(of: root) + [root]).filter { $0 > 1 && $0 != ownPID }
        guard !tree.isEmpty else { return }

        for pid in tree.reversed() { kill(pid, SIGTERM) }
        Thread.sleep(forTimeInterval: 1)
        for pid in tree.reversed() where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    static func runCLI(_ pm3: String, _ commands: [String], cwd: URL? = nil,
                       timeout: TimeInterval = quickCommandTimeout) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pm3)
        var args: [String] = []
        for c in commands { args += ["-c", c] }
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = cwd }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() }
        catch { return "[error] cannot launch pm3 at '\(pm3)': \(error.localizedDescription)" }

        let lock = NSLock()
        var collected = Data()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected = data; lock.unlock()
            finished.signal()
        }

        func collectedText() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: collected, encoding: .utf8) ?? ""
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            terminateProcessTree(root: proc.processIdentifier)
            _ = finished.wait(timeout: .now() + 5)
            return collectedText()
                + "\n[error] pm3 did not finish within \(Int(timeout))s and was stopped.\n"
                + "If the log says it is waiting for the Proxmark3, the device is not plugged in."
        }

        proc.waitUntilExit()
        return collectedText()
    }

    // MARK: parsing

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func grabUID(_ raw: String) -> String? {
        guard let g = firstGroup(#"UID[:\s]+((?:[0-9A-Fa-f]{2}[\s:]?){4,10})"#, in: raw)
        else { return nil }
        return g.filter { $0.isHexDigit }.uppercased()
    }

    static func hasCard(_ raw: String) -> Bool {
        if grabUID(raw) != nil { return true }
        for m in noCardMarkers where raw.range(of: m, options: .caseInsensitive) != nil {
            // weak negative; only trust it if nothing positive was seen
        }
        return raw.range(of: "MIFARE", options: .caseInsensitive) != nil
            || raw.range(of: "EM 410x", options: .caseInsensitive) != nil
    }

    /// Parse an `hf search` result into a track, or nil if no HF card.
    static func parseHF(_ raw: String) -> CardTrack? {
        for m in encryptedMarkers where raw.range(of: m, options: .caseInsensitive) != nil {
            return CardTrack(band: .hf, family: "encrypted", ident: grabUID(raw), cloneable: false)
        }
        // Require a UID. "MIFARE Classic" also appears in write and info
        // output ("Copying to magic gen1a MIFARE Classic 1K"), and a card
        // saved without a UID cannot be cloned or verified later.
        if raw.range(of: "MIFARE Classic", options: .caseInsensitive) != nil,
           let uid = grabUID(raw) {
            return CardTrack(band: .hf, family: "mifare_classic", ident: uid, cloneable: true)
        }
        if let uid = grabUID(raw) {
            return CardTrack(band: .hf, family: "unknown", ident: uid, cloneable: false)
        }
        return nil
    }

    /// Parse an `lf search` result into a track, or nil if no LF card.
    static func parseLF(_ raw: String) -> CardTrack? {
        if let id = em410xID(in: raw) {
            return CardTrack(band: .lf, family: "em410x", ident: id, cloneable: true)
        }
        if let id = hidProxRawID(in: raw) {
            return CardTrack(band: .lf, family: "hid_prox", ident: id, cloneable: true)
        }
        return nil
    }

    static func em410xID(in text: String) -> String? {
        let id = firstGroup(#"EM\s?410x\s+ID\s+([0-9A-Fa-f]{10})"#, in: text)
            ?? firstGroup(#"EM410x.*?ID[:\s]+([0-9A-Fa-f]{10})"#, in: text)
        return id?.uppercased()
    }

    /// `lf search` and `lf hid reader` print `[=] raw: 000000000000002004d2162e`
    /// alongside `Valid HID Prox ID found!`. The raw value is the identity that
    /// `lf hid clone -r` takes. The 26-bit and 27-bit format guesses printed
    /// above it are candidate decodings, not the card.
    static func hidProxRawID(in text: String) -> String? {
        guard text.range(of: "HID Prox", options: .caseInsensitive) != nil,
              let raw = firstGroup(#"raw:\s*([0-9A-Fa-f]{8,24})"#, in: text) else { return nil }
        return raw.lowercased()
    }

    /// Build an HID Prox track from a raw value typed or pasted by hand.
    static func hidProxTrack(fromRaw input: String) -> CardTrack? {
        let hex = input.filter { $0.isHexDigit }.lowercased()
        guard hex.count >= 8, hex.count <= 24, hex.count % 2 == 0 else { return nil }
        return CardTrack(band: .lf, family: "hid_prox", ident: hex, cloneable: true)
    }

    static func newestDump() -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dumpDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return items
            .filter { $0.lastPathComponent.hasPrefix("hf-mf-") && $0.lastPathComponent.hasSuffix("-dump.bin") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }.first
    }

    // MARK: manual import (no hardware)

    /// Build an EM410x track from a typed serial. Returns nil if not 10 hex.
    static func em410xTrack(fromSerial raw: String) -> CardTrack? {
        let hex = raw.filter { $0.isHexDigit }.uppercased()
        guard hex.count == 10 else { return nil }
        return CardTrack(band: .lf, family: "em410x", ident: hex, cloneable: true)
    }

    /// Copy an existing MIFARE dump set into the app and build an HF track.
    /// Accepts the whole autopwn output (dump.bin / .json / .eml / key.bin);
    /// the key file is kept beside the dump so Gen2 `restore` can find it.
    static func importMifareDump(from urls: [URL],
                                 into destination: URL? = nil) -> CardTrack? {
        let target = destination ?? dumpDir
        var copied: [URL] = []
        for url in urls {
            let dest = target.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                copied.append(dest)
            }
        }
        guard !copied.isEmpty else { return nil }

        func ext(_ u: URL) -> String { u.pathExtension.lowercased() }
        func isDump(_ u: URL) -> Bool { u.lastPathComponent.lowercased().contains("dump") }
        func isKeyFile(_ u: URL) -> Bool { u.lastPathComponent.lowercased().contains("key") }

        // A key file is not a dump. Writing one to a card would push 192 bytes
        // of key material onto the blank, so refuse rather than guess.
        let dumpCandidates = copied.filter { !isKeyFile($0) }
        guard let primary = dumpCandidates.first(where: { ext($0) == "bin" && isDump($0) })
            ?? dumpCandidates.first(where: { ext($0) == "json" })
            ?? dumpCandidates.first(where: { ext($0) == "eml" })
            ?? dumpCandidates.first(where: { isDump($0) })
            ?? dumpCandidates.first
        else {
            copied.forEach { try? FileManager.default.removeItem(at: $0) }
            return nil
        }

        var uid: String?
        for u in copied {
            if let g = firstGroup(#"hf-mf-([0-9A-Fa-f]{8,14})-"#, in: u.lastPathComponent) {
                uid = g.uppercased(); break
            }
        }
        if uid == nil, ext(primary) == "bin",
           let data = try? Data(contentsOf: primary), data.count >= 4 {
            uid = data.prefix(4).map { String(format: "%02X", $0) }.joined()
        }
        return CardTrack(band: .hf, family: "mifare_classic", ident: uid,
                         cloneable: true, dumpfile: primary.path)
    }

    // MARK: operations (async, off the main thread)

    /// Scan both bands. Returns every track present plus the combined raw log.
    static func scanTracks(pm3: String) async -> (tracks: [CardTrack], raw: String) {
        await Task.detached {
            var raw = ""
            var tracks: [CardTrack] = []

            let hfRaw = runCLI(pm3, ["hf search"])
            raw += "=== hf search ===\n" + hfRaw + "\n"
            if var hf = parseHF(hfRaw) {
                if hf.family == "mifare_classic" {
                    let pwn = runCLI(pm3, ["hf mf autopwn"], cwd: dumpDir, timeout: longCommandTimeout)
                    raw += "\n=== hf mf autopwn ===\n" + pwn + "\n"
                    hf.dumpfile = newestDump()?.path
                    if hf.dumpfile == nil { hf.cloneable = false }
                }
                tracks.append(hf)
            }

            let lfRaw = runCLI(pm3, ["lf search"])
            raw += "\n=== lf search ===\n" + lfRaw + "\n"
            if let lf = parseLF(lfRaw) { tracks.append(lf) }

            return (tracks, raw)
        }.value
    }

    enum MagicGen: String {
        case gen1a, gen2, gen3, gen4, none, unknown
        var label: String {
            switch self {
            case .gen1a: return "Gen1a"
            case .gen2: return "Gen2/CUID"
            case .gen3: return "Gen3"
            case .gen4: return "Gen4/GTU"
            case .none: return "not a magic card"
            case .unknown: return "unknown magic"
            }
        }
    }

    /// Fingerprint the magic generation of the card on the antenna.
    static func detectMagic(pm3: String) -> (MagicGen, String) {
        let raw = runCLI(pm3, ["hf mf info"])
        return (classifyMagic(raw), raw)
    }

    /// A real magic card reports several capabilities at once. A Gen1a blank
    /// also answers the Gen4 GDM / USCUID probe, so `hf mf info` prints
    /// "Gen 1a" and two "Gen 4 GDM / USCUID" lines together. Check from the
    /// most directly usable capability down, or a Gen1a card is read as Gen4
    /// and the clone is refused.
    static func classifyMagic(_ raw: String) -> MagicGen {
        func has(_ s: String) -> Bool { raw.range(of: s, options: .caseInsensitive) != nil }
        // "CUID" is a substring of "USCUID", which is a Gen4 marker, so the
        // Gen2 tokens have to match as whole words.
        func hasWord(_ s: String) -> Bool {
            raw.range(of: "\\b\(s)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }

        if has("Gen 1a") || has("Gen 1b") { return .gen1a }
        if has("Gen 2") || hasWord("CUID") || hasWord("FUID") { return .gen2 }
        if has("Gen 3") { return .gen3 }
        if has("Gen 4") || has("GTU") || has("USCUID") { return .gen4 }
        if has("Magic capabilities") { return .unknown }
        return .none
    }

    static func clone(pm3: String, track: CardTrack) async -> OpResult {
        await Task.detached {
            switch track.family {
            case "mifare_classic":
                guard let f = track.dumpfile, FileManager.default.fileExists(atPath: f) else {
                    return OpResult(ok: false, match: nil,
                                    message: "No dump stored for this track. Re-scan.", raw: "")
                }
                // Detect the blank before writing, then pick the command.
                let (gen, info) = detectMagic(pm3: pm3)
                var raw = "=== hf mf info ===\n" + info + "\n"
                let cmd: String
                switch gen {
                case .gen1a:
                    cmd = "hf mf cload -f \(f)"
                case .gen2:
                    // Gen2/CUID writes via normal auth; keyfile auto-found next to the dump.
                    cmd = "hf mf restore --1k -f \(f)"
                default:
                    return OpResult(ok: false, match: nil,
                                    message: "Blank is \(gen.label). Clone aborted. Use a Gen1a or Gen2 magic MIFARE card.",
                                    raw: raw)
                }
                raw += "\n=== \(cmd) ===\n" + runCLI(pm3, [cmd], cwd: dumpDir, timeout: longCommandTimeout)
                return OpResult(ok: true, match: nil,
                                message: "Detected \(gen.label) blank. Wrote MIFARE dump.", raw: raw)
            case "em410x":
                let raw = runCLI(pm3, ["lf em 410x clone --id \(track.ident ?? "")"])
                return OpResult(ok: true, match: nil,
                                message: "Wrote EM410x \(track.ident ?? "?") to T5577.", raw: raw)
            case "hid_prox":
                let raw = runCLI(pm3, ["lf hid clone -r \(track.ident ?? "")"])
                return OpResult(ok: true, match: nil,
                                message: "Wrote HID Prox \(track.ident ?? "?") to T5577.", raw: raw)
            default:
                return OpResult(ok: false, match: nil,
                                message: "\(track.familyLabel) cannot be cloned.", raw: "")
            }
        }.value
    }

    static func verify(pm3: String, track: CardTrack) async -> OpResult {
        await Task.detached {
            switch track.family {
            case "em410x":
                let raw = runCLI(pm3, ["lf em 410x reader"])
                let found = em410xID(in: raw)
                let match = (found != nil && found == track.ident?.uppercased())
                return OpResult(ok: true, match: match,
                                message: "Card \(found ?? "?") vs backup \(track.ident ?? "?"): "
                                    + (match ? "MATCH" : "MISMATCH"), raw: raw)
            case "hid_prox":
                let raw = runCLI(pm3, ["lf hid reader"])
                let found = hidProxRawID(in: raw)
                let match = (found != nil && found == track.ident?.lowercased())
                return OpResult(ok: true, match: match,
                                message: "Card \(found ?? "?") vs backup \(track.ident ?? "?"): "
                                    + (match ? "MATCH" : "MISMATCH"), raw: raw)
            case "mifare_classic":
                let raw = runCLI(pm3, ["hf 14a reader"])
                let found = grabUID(raw)
                let match = (found == track.ident)
                return OpResult(ok: true, match: match,
                                message: "UID \(found ?? "?") vs backup \(track.ident ?? "?"): "
                                    + (match ? "MATCH" : "MISMATCH") + " (UID only; block diff TODO).",
                                raw: raw)
            default:
                return OpResult(ok: false, match: nil,
                                message: "\(track.familyLabel) cannot be verified.", raw: "")
            }
        }.value
    }
}
