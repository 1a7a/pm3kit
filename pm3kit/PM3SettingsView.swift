import SwiftUI
import UniformTypeIdentifiers

enum PM3PathSetting {
    static let storageKey = "pm3Path"
    static let defaultPath = "/opt/homebrew/bin/pm3"
}

struct PM3SettingsView: View {
    @EnvironmentObject private var store: CardStore
    @AppStorage(PM3PathSetting.storageKey) private var pm3Path = PM3PathSetting.defaultPath
    @State private var backupStatus = ""
    @State private var backupFailed = false

    private var pm3IsExecutable: Bool {
        FileManager.default.isExecutableFile(atPath: pm3Path)
    }

    var body: some View {
        Form {
            Section {
                TextField("pm3 binary", text: $pm3Path, prompt: Text(PM3PathSetting.defaultPath))
                    .font(.system(.body, design: .monospaced))

                HStack(spacing: 6) {
                    Image(systemName: pm3IsExecutable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(pm3IsExecutable ? .green : .orange)
                    Text(pm3IsExecutable
                         ? "Found an executable at this path."
                         : "No executable here. Run `which pm3` in Terminal and paste the result.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Choose…") { choosePM3Binary() }
                    Button("Reset to default") { pm3Path = PM3PathSetting.defaultPath }
                        .disabled(pm3Path == PM3PathSetting.defaultPath)
                }
            } header: {
                Text("Proxmark3 CLI")
            } footer: {
                Text("pm3-kit runs this binary as a subprocess. Homebrew installs it at \(PM3PathSetting.defaultPath) on Apple Silicon and /usr/local/bin/pm3 on Intel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Backup…") { backUpLibrary() }
                        .disabled(store.cards.isEmpty)
                    Button("Restore…") { restoreLibrary() }
                    Spacer()
                    Text("\(store.cards.count) card(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !backupStatus.isEmpty {
                    Text(backupStatus)
                        .font(.caption)
                        .foregroundStyle(backupFailed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Library backup")
            } footer: {
                Text("Backup writes one archive file; the name defaults to today's date and you can change it. Restore reads a backup file and merges it, skipping cards already in the library. Dumps and key files are embedded, so a backup restores on any Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 390)
    }

    private func backUpLibrary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = LibraryArchiveStore.backupFilename()
        panel.message = "Choose where to store the backup."
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try LibraryArchiveStore.encodeArchive(cards: store.cards).write(to: url)
            backupFailed = false
            backupStatus = "Backed up \(store.cards.count) card(s) to \(url.lastPathComponent)."
        } catch {
            backupFailed = true
            backupStatus = "Backup failed: \(error.localizedDescription)"
        }
    }

    private func restoreLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a pm3-kit backup file to restore."
        panel.prompt = "Restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let archive = try LibraryArchiveStore.decodeArchive(from: try Data(contentsOf: url))
            let (cards, summary) = LibraryArchiveStore.restoreCards(from: archive, existing: store.cards)
            store.addRestored(cards)
            backupFailed = false

            var parts = ["Restored \(summary.importedCards) card(s) from \(url.lastPathComponent)."]
            if summary.skippedDuplicates > 0 {
                parts.append("Skipped \(summary.skippedDuplicates) already in the library.")
            }
            backupStatus = parts.joined(separator: " ")
        } catch {
            backupFailed = true
            backupStatus = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func choosePM3Binary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: pm3Path).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            pm3Path = url.path
        }
    }
}
