import SwiftUI

/// Proof of consent kept with a recording and every transcript exported
/// from it: who said on the recording that they agree to be recorded, and
/// when. A transcript can't be published without one naming two people.
struct ConsentEntry: Codable, Hashable {
    static let minimumNames = 2

    var names: [String]
    /// When "Everyone has agreed on the recording" was tapped.
    var date: Date?
    /// Seconds into the part's audio where consent was given.
    var audioTime: TimeInterval?
    /// Recording (part) the spoken consent is on.
    var recordingTitle: String?

    var isEnough: Bool { names.count >= Self.minimumNames }

    var summary: String {
        var text = "Consent: \(names.joined(separator: ", "))"
        if let audioTime {
            let total = Int(audioTime.rounded())
            text += " · on the recording at \(total / 60):\(String(format: "%02d", total % 60))"
        }
        if let recordingTitle { text += " of “\(recordingTitle)”" }
        if let date { text += " · \(date.formatted(date: .abbreviated, time: .shortened))" }
        return text
    }

    static let missingMessage = "This transcript has no consent entry naming at least two people. Only transcripts exported from a recording where everyone’s names were entered when they agreed on the recording can be published."

    /// Names typed in the form, trimmed, blanks dropped.
    static func cleaned(_ names: [String]) -> [String] {
        names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension Recording {
    /// The consent entry for this recording's session. Consent is saved on
    /// the part where it was given, so later parts look it up there.
    var sessionConsent: ConsentEntry? {
        let parts = sessionID.map { id in Store.loadAll().filter { $0.sessionID == id } } ?? []
        return ([self] + parts.sorted { ($0.partNumber ?? 0) < ($1.partNumber ?? 0) })
            .lazy.compactMap(\.ownConsent).first
    }

    /// Consent entered on this part itself.
    var ownConsent: ConsentEntry? {
        guard let names = consentedBy, !names.isEmpty else { return nil }
        return ConsentEntry(names: names, date: consentDate, audioTime: consentAudioTime, recordingTitle: title)
    }

    /// Consent from this phone's recordings of a shared meeting.
    static func meetingConsent(code: String) -> ConsentEntry? {
        Store.loadAll().filter { $0.meetingCode == code }
            .compactMap(\.sessionConsent)
            .max { $0.names.count < $1.names.count }
    }
}

/// Green consent line, or an orange warning when there isn't enough.
struct ConsentBadge: View {
    let consent: ConsentEntry?

    var body: some View {
        if let consent, consent.isEnough {
            Label(consent.summary, systemImage: "person.2.badge.key.fill")
                .foregroundStyle(.green)
        } else {
            Label("No consent entry with two names — can’t be published",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// The consent entry form: the name of each person who said on the
/// recording that they agree. At least two names are needed.
struct ConsentEntrySheet: View {
    var initialNames: [String] = []
    var onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = ["", ""]
    @FocusState private var focused: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(names.indices, id: \.self) { index in
                        TextField("Person \(index + 1) name", text: $names[index])
                            .textContentType(.name)
                            .focused($focused, equals: index)
                    }
                    .onDelete { offsets in
                        if names.count - offsets.count >= ConsentEntry.minimumNames { names.remove(atOffsets: offsets) }
                    }
                    Button("Add Person", systemImage: "person.badge.plus") {
                        names.append("")
                        focused = names.count - 1
                    }
                } header: {
                    Text("Who agreed on the recording")
                } footer: {
                    Text("Enter the name of each person who said their name and that they agree to be recorded. At least two names are needed, or transcripts from this recording can’t be published.")
                }
            }
            .navigationTitle("Consent Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(ConsentEntry.cleaned(names))
                        dismiss()
                    }
                    .disabled(ConsentEntry.cleaned(names).count < ConsentEntry.minimumNames)
                }
            }
            .onAppear {
                if !initialNames.isEmpty {
                    names = initialNames + Array(repeating: "", count: max(0, ConsentEntry.minimumNames - initialNames.count))
                }
                focused = 0
            }
        }
    }
}
