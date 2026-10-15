import AppIntents
import Foundation

// Shortcuts and Siri actions. They run inside DiTether (in the background unless they open the app),
// so they reach the one PhoneModel. Use them in Personal Automations, for example "When I arrive at
// Work → Start Quiet Mode", or put "Open DiTAG Camera" on the Action button.

// MARK: - DiTAG as a Shortcuts parameter

struct DiTagEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "DiTAG"
    static let defaultQuery = DiTagQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "tag.fill"))
    }
}

struct DiTagQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [DiTagEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DiTagEntity] {
        // Read straight from the saved settings, so this works before the app model exists.
        let tags = JSONFile<DiTagSettings>(name: "ditag-settings.json").load()?.tags ?? []
        return tags.map { DiTagEntity(id: $0.id, name: $0.displayName) }
    }
}

enum DiTetherIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case noTags

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "DiTether isn't ready yet. Open it once, then try again."
        case .noTags: return "No DiTAG is set up yet. Add one in DiTether first."
        }
    }
}

@MainActor
private func diTagModel() throws -> PhoneModel {
    guard let model = PhoneModel.shared else { throw DiTetherIntentError.notReady }
    return model
}

@MainActor
private func targetIDs(_ tag: DiTagEntity?, in model: PhoneModel) throws -> [UUID] {
    let all = model.diTag.settings.tags.map(\.id)
    guard !all.isEmpty else { throw DiTetherIntentError.noTags }
    if let tag { return [tag.id] }
    return all
}

// MARK: - Quiet mode

struct StartQuietModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Quiet Mode"
    static let description = IntentDescription("Politely disconnects your DiTAGs so leaving them somewhere on purpose makes no noise on your iPhone.")
    static let openAppWhenRun = false

    @Parameter(title: "DiTAG", description: "Leave empty for all DiTAGs.")
    var tag: DiTagEntity?

    @Parameter(title: "Minutes", description: "Leave empty to stay quiet until you end it.", inclusiveRange: (1, 1440))
    var minutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Start Quiet Mode for \(\.$tag)") {
            \.$minutes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try diTagModel()
        let ids = try targetIDs(tag, in: model)
        let until = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        model.diTag.startQuiet(ids, until: until)
        let who = tag?.name ?? "Your DiTAGs"
        if let until {
            return .result(dialog: "\(who) will stay quiet until \(until.formatted(date: .omitted, time: .shortened)).")
        }
        return .result(dialog: "\(who) will stay quiet until you end Quiet Mode.")
    }
}

struct EndQuietModeIntent: AppIntent {
    static let title: LocalizedStringResource = "End Quiet Mode"
    static let description = IntentDescription("Reconnects your DiTAGs and watches them again.")
    static let openAppWhenRun = false

    @Parameter(title: "DiTAG", description: "Leave empty for all DiTAGs.")
    var tag: DiTagEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try diTagModel()
        model.diTag.endQuiet(try targetIDs(tag, in: model))
        return .result(dialog: "Reconnecting to \(tag?.name ?? "your DiTAGs").")
    }
}

// MARK: - Ring a DiTAG

struct RingTagIntent: AppIntent {
    static let title: LocalizedStringResource = "Ring DiTAG"
    static let description = IntentDescription("Makes a DiTAG beep for 5 seconds so you can find it.")
    static let openAppWhenRun = false

    @Parameter(title: "DiTAG", description: "Leave empty to ring every DiTAG nearby.")
    var tag: DiTagEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try diTagModel()
        let rang = await model.diTag.beepBriefly(try targetIDs(tag, in: model))
        if rang == 0 {
            return .result(dialog: "Couldn't reach \(tag?.name ?? "a DiTAG"). It may be out of range or switched off.")
        }
        return .result(dialog: "Ringing \(tag?.name ?? (rang == 1 ? "your DiTAG" : "\(rang) DiTAGs")).")
    }
}

// MARK: - Save my spot

struct SaveSpotIntent: AppIntent {
    static let title: LocalizedStringResource = "Save My Spot"
    static let description = IntentDescription("Saves where you are now on the DiTether Places map, for example where you parked.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try diTagModel()
        model.diTag.saveSpot()
        return .result(dialog: "Saving this spot on your Places map.")
    }
}

// MARK: - Camera

struct OpenCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open DiTAG Camera"
    static let description = IntentDescription("Opens the DiTether camera, ready for a DiTAG press to take the photo.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try diTagModel()
        model.showCamera = true
        return .result()
    }
}

// MARK: - Siri phrases and the Shortcuts app

struct DiTetherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCameraIntent(),
                    phrases: ["Open \(.applicationName) camera", "Take a photo with \(.applicationName)"],
                    shortTitle: "DiTAG Camera", systemImageName: "camera.fill")
        AppShortcut(intent: StartQuietModeIntent(),
                    phrases: ["Start quiet mode in \(.applicationName)", "Silence my tags in \(.applicationName)"],
                    shortTitle: "Start Quiet Mode", systemImageName: "moon.zzz.fill")
        AppShortcut(intent: EndQuietModeIntent(),
                    phrases: ["End quiet mode in \(.applicationName)"],
                    shortTitle: "End Quiet Mode", systemImageName: "bell.fill")
        AppShortcut(intent: RingTagIntent(),
                    phrases: ["Ring my tag with \(.applicationName)", "Find my keys with \(.applicationName)"],
                    shortTitle: "Ring DiTAG", systemImageName: "speaker.wave.3.fill")
        AppShortcut(intent: SaveSpotIntent(),
                    phrases: ["Save my spot in \(.applicationName)", "Remember where I parked with \(.applicationName)"],
                    shortTitle: "Save My Spot", systemImageName: "mappin.and.ellipse")
    }
}
