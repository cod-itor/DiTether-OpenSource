import SwiftUI

/// Speed versus battery, as three tappable rows with an honest summary each.
struct DetectionModePicker: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        ForEach(DetectionMode.allCases) { mode in
            DetectionModeRow(mode: mode, isSelected: model.settings.settings.detectionMode == mode) {
                model.edit { $0.detectionMode = mode }
            }
        }
    }
}

struct DetectionModeRow: View {
    let mode: DetectionMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if mode == .balanced {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(mode.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var color: Color {
        switch mode {
        case .fast: return .orange
        case .balanced: return .blue
        case .saver: return .green
        }
    }
}
