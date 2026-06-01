import SwiftUI

// MARK: - Create Job View

struct CreateJobView: View {
    @EnvironmentObject var scheduler: JobScheduler
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var workingDirectory: String = ""
    @State private var tags: String = ""
    @State private var selectedMatlabOption: String = ""
    @State private var customMatlabPath: String = ""
    @State private var extraArgs: String = ""

    @State private var detectedMatlabs: [MATLABDetector.MATLABInstallation] = []

    private let customMatlabTag = "__custom__"

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Task") {
                    LabeledContent("Name") {
                        TextField("e.g. Main_Robust full run", text: $name)
                    }

                    LabeledContent("MATLAB Command") {
                        TextEditor(text: $command)
                            .font(.body.monospaced())
                            .frame(minHeight: 80)
                    }
                }

                Section("Environment") {
                    LabeledContent("Working Directory") {
                        HStack {
                            TextField("/path/to/project", text: $workingDirectory)
                                .font(.system(.body, design: .monospaced))
                            Button("Browse...") {
                                browseDirectory()
                            }
                        }
                    }

                    LabeledContent("MATLAB") {
                        Picker("MATLAB", selection: $selectedMatlabOption) {
                            ForEach(detectedMatlabs) { matlab in
                                Text(matlab.displayName).tag(matlab.binaryPath)
                            }
                            Text("Custom Path").tag(customMatlabTag)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 280)
                    }

                    if selectedMatlabOption == customMatlabTag {
                        LabeledContent("Custom Path") {
                            TextField("/Applications/MATLAB_R2026a.app/bin/matlab", text: $customMatlabPath)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Section("Optional") {
                    LabeledContent("Tags") {
                        TextField("comma separated", text: $tags)
                    }

                    LabeledContent("Extra Arguments") {
                        TextField("e.g. -nojvm -nosplash", text: $extraArgs)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Submit Task") {
                    submitJob()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
        .onAppear {
            detectedMatlabs = MATLABDetector.detectInstallations()
            configureInitialMatlabSelection()
        }
    }

    private var resolvedMatlabPath: String {
        selectedMatlabOption == customMatlabTag ? customMatlabPath : selectedMatlabOption
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !resolvedMatlabPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func configureInitialMatlabSelection() {
        let defaultPath = scheduler.settings.defaultMatlabPath
        customMatlabPath = defaultPath

        if detectedMatlabs.contains(where: { $0.binaryPath == defaultPath }) {
            selectedMatlabOption = defaultPath
        } else {
            selectedMatlabOption = customMatlabTag
        }
    }

    private func submitJob() {
        let parsedTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let parsedExtraArgs = extraArgs
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let submission = JobSubmission(
            name: name,
            matlabPath: resolvedMatlabPath,
            workingDirectory: workingDirectory,
            command: command,
            tags: parsedTags.isEmpty ? nil : parsedTags,
            extraArgs: parsedExtraArgs.isEmpty ? nil : parsedExtraArgs,
            environment: nil
        )

        _ = scheduler.submitJob(submission)
        dismiss()
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select Working Directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }
}
