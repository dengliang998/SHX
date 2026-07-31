import SwiftUI

struct ConnectionTagSelector: View {
    @Binding var selectedTags: Set<String>
    let availableTags: [String]
    @State private var customTag = ""

    private var orderedSelection: [String] {
        ConnectionOrganization.normalizeTags(selectedTags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("标签")
                Spacer()
                Menu {
                    ForEach(availableTags, id: \.self) { tag in
                        Button {
                            toggle(tag)
                        } label: {
                            if selectedTags.contains(tag) {
                                Label(ConnectionOrganization.displayName(forTag: tag), systemImage: "checkmark")
                            } else {
                                Text(ConnectionOrganization.displayName(forTag: tag))
                            }
                        }
                    }
                } label: {
                    Label("选择标签", systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
            }

            if orderedSelection.isEmpty {
                Text("尚未添加标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(orderedSelection, id: \.self) { tag in
                            Button {
                                selectedTags.remove(tag)
                            } label: {
                                Label(ConnectionOrganization.displayName(forTag: tag), systemImage: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("移除标签")
                        }
                    }
                }
            }

            HStack {
                TextField("自定义标签", text: $customTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCustomTag)
                Button("添加", action: addCustomTag)
                    .disabled(customTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func toggle(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func addCustomTag() {
        let tag = customTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        selectedTags.insert(tag)
        customTag = ""
    }
}
