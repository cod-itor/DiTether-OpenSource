import SwiftUI
import UIKit

/// A checklist row that does something when tapped, if its step has an action
/// (open Safe places, ask for location). Steps without an action are plain rows.
struct SetupStepLink: View {
    @EnvironmentObject private var model: PhoneModel
    let step: SetupStep

    var body: some View {
        switch step.id {
        case .safePlace where !step.isDone:
            NavigationLink {
                SafePlacesView()
            } label: {
                SetupStepRow(step: step)
            }
        case .phoneLocation where !step.isDone:
            Button {
                if model.location.isDenied {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    model.location.requestSharingAuthorization()
                }
            } label: {
                SetupStepRow(step: step)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .paired where !step.isDone, .installed where !step.isDone:
            Button {
                model.launcher.openWatchAppOnPhone()
            } label: {
                SetupStepRow(step: step)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .watchSetUp where !step.isDone:
            Button {
                model.launcher.openOnWatch()
            } label: {
                SetupStepRow(step: step)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .bluetooth where !step.isDone:
            Button {
                if model.beacon.isDenied {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    model.beacon.start()   // shows the Bluetooth permission prompt
                }
            } label: {
                SetupStepRow(step: step)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        default:
            SetupStepRow(step: step)
        }
    }
}
