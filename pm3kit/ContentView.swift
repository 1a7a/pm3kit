import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: CardStore
    @AppStorage(PM3PathSetting.storageKey) private var pm3Path = PM3PathSetting.defaultPath
    @State private var selection: SavedCard.ID?
    @State private var busy = false
    @State private var log = "ready."
    @State private var verifyResult: [UUID: Bool] = [:]   // track id -> match

    // manual import
    enum AddMode { case newCard, attachToSelected }

    @State private var lfSheetFamily: LFCardFamily?
    @AppStorage("cardSortOrder") private var cardSortOrder = CardSortOrder.manual.rawValue

    // Do not bind the name and notes fields straight into store.cards[i]:
    // cards has didSet { save() }, so each keystroke republishes the library
    // and rebuilds the field, which drops what was typed.
    @State private var nameDraft = ""
    @State private var notesDraft = ""
    @State private var draftCardID: SavedCard.ID?
    @State private var addMode: AddMode = .newCard
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear { loadDrafts(for: selection) }
        .onChange(of: selection) { _, newSelection in loadDrafts(for: newSelection) }
        .onChange(of: nameDraft) { _, newName in commitDraft { $0.name = newName } }
        .onChange(of: notesDraft) { _, newNotes in commitDraft { $0.notes = newNotes } }
        .sheet(item: $lfSheetFamily) { family in
            AddLFCardSheet(family: family,
                           defaultName: addMode == .attachToSelected ? nameDraft : "",
                           onAdd: { track, chosen, name in
                               lfSheetFamily = nil
                               addLFTrack(track, family: chosen, name: name)
                           },
                           onCancel: { lfSheetFamily = nil })
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            handleImport(result)
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Button(action: scanNew) {
                    Label("Scan new card", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                Menu {
                    Button("Add EM410x by ID…") {
                        addMode = .newCard; lfSheetFamily = .em410x
                    }
                    Button("Add HID Prox by raw…") {
                        addMode = .newCard; lfSheetFamily = .hidProx
                    }
                    Button("Import MIFARE dump files…") {
                        addMode = .newCard; showImporter = true
                    }
                } label: {
                    Label("Add existing", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
                .disabled(busy)

                Picker("Sort", selection: $cardSortOrder) {
                    ForEach(CardSortOrder.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .font(.caption)
            }
            .padding(10)

            List(selection: $selection) {
                ForEach(displayedCards) { card in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(card.name).fontWeight(.medium)
                            if card.isDual {
                                Text("dual").font(.caption2).bold()
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(card.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(card.id)
                }
                .onMove(perform: sortOrder.isDraggable ? moveCards : nil)
            }

            Divider()
            pm3SettingsBar
        }
        .frame(minWidth: 220)
    }

    private var sortOrder: CardSortOrder {
        CardSortOrder(rawValue: cardSortOrder) ?? .manual
    }

    private var displayedCards: [SavedCard] {
        sortOrder.arrange(store.cards)
    }

    private func moveCards(from offsets: IndexSet, to destination: Int) {
        store.cards.move(fromOffsets: offsets, toOffset: destination)
    }

    private var pm3SettingsBar: some View {
        HStack(spacing: 6) {
            SettingsLink {
                Label("pm3 settings", systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            Spacer()
            Image(systemName: pm3IsExecutable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(pm3IsExecutable ? .green : .orange)
                .help(pm3IsExecutable
                      ? "pm3 found at \(pm3Path)"
                      : "No executable at \(pm3Path). Open pm3 settings to fix the path.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var pm3IsExecutable: Bool {
        FileManager.default.isExecutableFile(atPath: pm3Path)
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        if let id = selection, let i = store.index(of: id) {
            cardDetail($store.cards[i])
        } else {
            VStack(spacing: 8) {
                Image(systemName: "creditcard").font(.largeTitle).foregroundStyle(.secondary)
                Text("Scan a card or pick one from the list.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadDrafts(for id: SavedCard.ID?) {
        guard let id, let i = store.index(of: id) else {
            draftCardID = nil
            nameDraft = ""
            notesDraft = ""
            return
        }
        draftCardID = id
        nameDraft = store.cards[i].name
        notesDraft = store.cards[i].notes
    }

    private func commitDraft(_ change: (inout SavedCard) -> Void) {
        guard let id = draftCardID, id == selection, let i = store.index(of: id) else { return }
        var edited = store.cards[i]
        change(&edited)
        guard edited != store.cards[i] else { return }
        store.cards[i] = edited
    }

    private func cardDetail(_ card: Binding<SavedCard>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Card name", text: $nameDraft)
                .textFieldStyle(.plain).font(.title2).bold()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))

            Text("Scanned \(card.wrappedValue.created.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(card.wrappedValue.tracks) { track in
                trackRow(track)
            }

            addTrackBar(card.wrappedValue)

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notesDraft)
                    .frame(height: 54)
                    .font(.callout)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            logPane

            HStack {
                Button(role: .destructive) {
                    store.delete(card.wrappedValue.id); selection = nil
                } label: { Label("Delete card", systemImage: "trash") }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func trackRow(_ track: CardTrack) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.bandLabel).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(track.familyLabel).fontWeight(.semibold)
                    Text(track.ident ?? "—").font(.system(.body, design: .monospaced))
                    if !track.cloneable {
                        badge("cannot clone", ok: false)
                    }
                    if let match = verifyResult[track.id] {
                        badge(match ? "verified" : "mismatch", ok: match)
                    }
                }
            }
            Spacer()
            Button("Clone") { runTrack("clone", track) }
                .disabled(busy || !track.cloneable)
            Button("Verify") { runTrack("verify", track) }
                .disabled(busy || !track.cloneable)
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Buttons to fill a missing band, so a card can become dual-frequency.
    @ViewBuilder private func addTrackBar(_ card: SavedCard) -> some View {
        let hasLF = card.tracks.contains { $0.band == .lf }
        let hasHF = card.tracks.contains { $0.band == .hf }
        if !hasLF || !hasHF {
            HStack(spacing: 10) {
                if !hasLF {
                    Button {
                        addMode = .attachToSelected; lfSheetFamily = .em410x
                    } label: { Label("Add EM410x track", systemImage: "plus") }
                    Button {
                        addMode = .attachToSelected; lfSheetFamily = .hidProx
                    } label: { Label("Add HID Prox track", systemImage: "plus") }
                }
                if !hasHF {
                    Button {
                        addMode = .attachToSelected; showImporter = true
                    } label: { Label("Import MIFARE track", systemImage: "plus") }
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var logPane: some View {
        ScrollView {
            Text(log)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: .infinity)
        .padding(10)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func badge(_ text: String, ok: Bool) -> some View {
        Text(text).font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background((ok ? Color.green : Color.red).opacity(0.18))
            .foregroundStyle(ok ? .green : .red)
            .clipShape(Capsule())
    }

    // MARK: actions

    private func scanNew() {
        busy = true
        log = "scanning...\n"
        Task {
            let (tracks, raw) = await PM3.scanTracks(pm3: pm3Path)
            if tracks.isEmpty {
                log = "No card detected.\n\n" + raw
            } else {
                let name = "Card \(store.cards.count + 1)"
                let card = store.add(name: name, tracks: tracks)
                selection = card.id
                let kinds = tracks.map { "\($0.bandLabel) \($0.familyLabel)" }.joined(separator: ", ")
                log = "Saved \(name): \(kinds)\n\n" + raw
            }
            busy = false
        }
    }

    private func runTrack(_ op: String, _ track: CardTrack) {
        busy = true
        log = "\(op) \(track.bandLabel)...\n"
        Task {
            let r = op == "clone"
                ? await PM3.clone(pm3: pm3Path, track: track)
                : await PM3.verify(pm3: pm3Path, track: track)
            if op == "verify", let m = r.match { verifyResult[track.id] = m }
            log = r.message + "\n\n" + r.raw
            busy = false
        }
    }

    // MARK: manual import

    private func addLFTrack(_ track: CardTrack, family: LFCardFamily, name: String) {
        if addMode == .attachToSelected, let id = selection {
            store.addTrack(to: id, track)
            log = "Added \(family.label) \(track.ident ?? "") track to this card (now dual-frequency)."
        } else {
            let cardName = name.isEmpty ? "\(family.label) \(track.ident ?? "")" : name
            let card = store.add(name: cardName, tracks: [track])
            selection = card.id
            log = "Added \(cardName): \(family.label) \(track.ident ?? "")"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, !urls.isEmpty else { return }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        guard let track = PM3.importMifareDump(from: urls) else {
            log = "Could not import the selected files.\n"
                + "Include the dump itself (a -dump.bin, -dump.json or -dump.eml file), "
                + "not just the -key.bin."
            return
        }
        let names = urls.map { $0.lastPathComponent }.joined(separator: ", ")
        let base = "Imported \(urls.count) file(s): \(names)\nMIFARE UID \(track.ident ?? "?").\n"
            + "Gen1a clone works from the dump alone. Gen2 restore needs the key file too, so include it."
        if addMode == .attachToSelected, let id = selection {
            store.addTrack(to: id, track)
            log = base + "\nAttached as the HF track (now dual-frequency)."
        } else {
            let card = store.add(name: "Imported \(track.ident ?? "MIFARE")", tracks: [track])
            selection = card.id
            log = base
        }
    }
}
