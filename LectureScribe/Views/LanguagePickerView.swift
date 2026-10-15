import SwiftUI

struct LanguagePickerView: View {
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var options: [LanguageOption] = []
    @State private var search = ""

    var body: some View {
        List {
            if options.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                Section {
                    ForEach(filteredOptions) { option in
                        Button {
                            selection = option.id
                            dismiss()
                        } label: {
                            row(for: option)
                        }
                    }
                } footer: {
                    Text("Languages marked **Best** use Apple's newest on-device model, built for long recordings like lectures (iOS 26 and later). The others use Apple's standard speech recognition, which may need an internet connection.")
                }
            }
        }
        .navigationTitle("Lecture Language")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search languages")
        .task {
            options = await LanguageCatalog.load()
        }
    }

    private var filteredOptions: [LanguageOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func row(for option: LanguageOption) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.name)
                    .foregroundStyle(.primary)
                Text(option.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if option.usesAdvancedModel {
                Text("Best")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.18), in: Capsule())
                    .foregroundStyle(.green)
            }
            if option.id == selection {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
