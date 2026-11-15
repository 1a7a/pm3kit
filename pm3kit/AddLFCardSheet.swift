import SwiftUI

enum LFCardFamily: String, CaseIterable, Identifiable {
    case em410x
    case hidProx

    var id: String { rawValue }

    var label: String {
        switch self {
        case .em410x: return "EM410x"
        case .hidProx: return "HID Prox"
        }
    }

    var fieldPrompt: String {
        switch self {
        case .em410x: return "Serial, 10 hex (e.g. 1A2B3C4D5E)"
        case .hidProx: return "Raw value, 8 to 24 hex digits"
        }
    }

    var requirement: String {
        switch self {
        case .em410x: return "Needs exactly 10 hex digits."
        case .hidProx: return "Needs 8 to 24 hex digits, an even number of them."
        }
    }

    var explanation: String {
        switch self {
        case .em410x:
            return "The 10-hex serial is the whole card. No scan needed; clone it straight to a T5577."
        case .hidProx:
            return "Paste the raw value `lf search` prints, such as 000000000000002004d2162e. That value is the whole card. The 26-bit and 27-bit guesses printed beside it (H10301, Indala, Tecom) are candidate decodings of one signal, not separate identities."
        }
    }

    func makeTrack(from input: String) -> CardTrack? {
        switch self {
        case .em410x: return PM3.em410xTrack(fromSerial: input)
        case .hidProx: return PM3.hidProxTrack(fromRaw: input)
        }
    }
}

struct AddLFCardSheet: View {
    let defaultName: String
    let onAdd: (CardTrack, LFCardFamily, String) -> Void
    let onCancel: () -> Void

    @State private var family: LFCardFamily
    @State private var name: String
    @State private var identifier = ""

    init(family: LFCardFamily,
         defaultName: String,
         onAdd: @escaping (CardTrack, LFCardFamily, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.defaultName = defaultName
        self.onAdd = onAdd
        self.onCancel = onCancel
        _family = State(initialValue: family)
        _name = State(initialValue: defaultName)
    }

    private var builtTrack: CardTrack? { family.makeTrack(from: identifier) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(family.label)").font(.headline)

            Picker("Type", selection: $family) {
                ForEach(LFCardFamily.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(family.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name (e.g. Garage remote)", text: $name)
                .textFieldStyle(.roundedBorder)

            // The placeholder is part of the field's identity on macOS, so it
            // does not refresh when the string changes. Rebuild on a switch.
            TextField(family.fieldPrompt, text: $identifier)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .id(family)

            if !identifier.isEmpty && builtTrack == nil {
                Text(family.requirement).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Add") {
                    guard let track = builtTrack else { return }
                    onAdd(track, family, name)
                }
                .buttonStyle(.borderedProminent)
                .disabled(builtTrack == nil)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}
