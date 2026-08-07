import AppKit
import SwiftUI

struct DisplayMenuView: View {
    @EnvironmentObject private var controller: DisplayController
    @AppStorage("appLanguage") private var languageCode = AppLanguage.vietnamese.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .vietnamese
    }

    private var strings: AppStrings {
        AppStrings(language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if controller.displays.isEmpty {
                ContentUnavailableView(
                    strings.noDisplays,
                    systemImage: "display.slash",
                    description: Text(strings.scanAgain)
                )
                .frame(width: 400, height: 170)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(controller.displays) { display in
                            DisplayRow(display: display, strings: strings)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 420, height: listHeight)
            }

            if let lastError = controller.lastError {
                Divider()
                Label(strings.errorMessage(for: lastError), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }

            Divider()
            actions
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("PypyDisplay")
                    .font(.headline)
                Text(strings.displayCount(active: controller.activeDisplayCount, total: controller.displays.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(strings.rescanDisplays)
        }
        .padding(12)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack {
                Label(
                    strings.displaysAwake,
                    systemImage: controller.displaysAwake ? "sun.max.fill" : "moon.zzz.fill"
                )
                Spacer()
                Toggle(
                    strings.displaysAwake,
                    isOn: Binding(
                        get: { controller.displaysAwake },
                        set: { controller.setDisplaysAwake($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Text(masterToggleDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(strings.connectionManagement)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    Label(strings.autoDisconnectBuiltIn, systemImage: "macbook")
                    Spacer()
                    Toggle(
                        strings.autoDisconnectBuiltIn,
                        isOn: Binding(
                            get: { controller.autoDisconnectBuiltInDisplay },
                            set: { controller.setAutoDisconnectBuiltInDisplay($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(
                        !controller.connectionManagementAvailable ||
                        !controller.hasBuiltInDisplay
                    )
                }

                Text(strings.autoDisconnectDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(strings.quit) {
                    NSApplication.shared.terminate(nil)
                }
            }

            HStack {
                Label(strings.languageLabel, systemImage: "globe")
                Spacer()
                Picker(strings.languageLabel, selection: $languageCode) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(strings.languageName(option)).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
            }

            HStack(spacing: 4) {
                Text("\(strings.authorLabel):")
                Text("Stephen31")
                    .fontWeight(.medium)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(12)
    }

    private var masterToggleDescription: String {
        strings.masterDescription(hotKey: GlobalHotKeyManager.keyDescription)
    }

    private var listHeight: CGFloat {
        let rowsHeight = controller.displays.reduce(CGFloat.zero) { height, display in
            guard display.isActive else { return height + 76 }
            return height + (display.isBuiltIn ? 214 : 184)
        }
        return min(rowsHeight + 24, 500)
    }
}

private struct DisplayRow: View {
    @EnvironmentObject private var controller: DisplayController
    let display: DisplayDevice
    let strings: AppStrings

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: display.isBuiltIn ? "macbook" : "display")
                    .font(.title2)
                    .foregroundStyle(display.isActive ? .blue : .secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(display.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)

                        if display.isMain {
                            Text("MAIN")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }

                    Text("\(strings.displayKind(isBuiltIn: display.isBuiltIn)) · \(resolutionLabel) · \(display.identifierLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Toggle(
                    strings.connectionToggleLabel(displayName: display.name),
                    isOn: Binding(
                        get: { display.isActive },
                        set: { controller.setDisplayConnection(display, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!controller.canChangeConnection(of: display))
                .help(connectionToggleHelp)
            }

            if display.isActive {
                Divider()
                displaySettings
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var displaySettings: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Label(strings.resolution, systemImage: "rectangle.arrowtriangle.2.outward")
                    .font(.caption)
                    .frame(width: 94, alignment: .leading)

                Picker(
                    strings.resolution,
                    selection: Binding(
                        get: { controller.currentModeID(for: display) },
                        set: { controller.setResolution($0, for: display) }
                    )
                ) {
                    ForEach(controller.resolutionOptions(for: display)) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(controller.resolutionOptions(for: display).isEmpty)
            }

            HStack(spacing: 10) {
                Label(
                    controller.usesSoftwareBrightness(for: display)
                        ? strings.softwareBrightness
                        : strings.brightness,
                    systemImage: "sun.max.fill"
                )
                    .font(.caption)
                    .frame(width: 94, alignment: .leading)

                if controller.supportsBrightness(for: display) {
                    Slider(
                        value: Binding(
                            get: { controller.brightness(for: display) },
                            set: { controller.setBrightness($0, for: display) }
                        ),
                        in: 0.05...1
                    )
                    .controlSize(.small)

                    Text("\(Int((controller.brightness(for: display) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                } else {
                    Text(strings.brightnessUnavailable)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            HStack(spacing: 10) {
                Label(strings.eyeProtection, systemImage: "eye.fill")
                    .font(.caption)
                    .frame(width: 94, alignment: .leading)

                Spacer()

                Toggle(
                    strings.eyeProtection,
                    isOn: Binding(
                        get: { controller.eyeProtectionEnabled(for: display) },
                        set: { controller.setEyeProtection($0, for: display) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(strings.eyeProtectionHelp)
            }

            if display.isBuiltIn {
                HStack(spacing: 10) {
                    Label(strings.trueTone, systemImage: "circle.lefthalf.filled")
                        .font(.caption)
                        .frame(width: 94, alignment: .leading)

                    Spacer()

                    if controller.supportsTrueTone(for: display) {
                        Toggle(
                            strings.trueTone,
                            isOn: Binding(
                                get: { controller.trueToneEnabled },
                                set: { controller.setTrueTone($0, for: display) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(strings.trueToneHelp)
                    } else {
                        Text(strings.trueToneUnavailable)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var resolutionLabel: String {
        guard display.pixelWidth > 0, display.pixelHeight > 0 else {
            return strings.unknownResolution
        }
        return "\(display.pixelWidth) × \(display.pixelHeight)"
    }

    private var connectionToggleHelp: String {
        if !controller.canChangeConnection(of: display) {
            return strings.lastDisplayHelp
        }
        return display.isActive
            ? strings.disconnectHelp(displayName: display.name)
            : strings.connectHelp(displayName: display.name)
    }
}
