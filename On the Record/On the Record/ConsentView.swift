import SwiftUI

/// Explicit consent gate shown before every recording. Recording cannot
/// be set up until the switch confirms everyone in the room has agreed.
struct ConsentView: View {
    var onContinue: () -> Void
    var onCancel: () -> Void

    @State private var everyoneAgreed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "person.2.wave.2.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity)
                        Text("Before you record")
                            .font(.title2.bold())
                        bullet("Tell everyone in the room you are recording, and get their OK.")
                        bullet("Recording starts only when you press Record on the next screen.")
                        bullet("As soon as recording starts, get everyone’s consent again — on the recording. Have each person say their name and that they agree to be recorded. Nothing should be discussed until every person in the room has done this.")
                        bullet("This is your legal protection: the recording itself proves everyone agreed, so no one can later deny it.")
                        bullet("A red “Recording” banner shows while the app is open; if the screen locks, iOS shows the mic indicator. It stops only when you tap Stop.")
                        bullet("Recording others without their consent may be illegal where you are.")
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Toggle("Everyone in the room has agreed to be recorded", isOn: $everyoneAgreed)
                }

                Section {
                    Button {
                        onContinue()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!everyoneAgreed)
                    .listRowBackground(Color.clear)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
            Text(text)
        }
        .font(.callout)
    }
}
