import Foundation
import Testing
@testable import stagekeeper

@Suite struct NumberedTests {
    private func stage(_ label: String?, id: Bool = true) -> SavedStage {
        SavedStage(id: id ? UUID() : nil, label: label, color: nil, current: false, windows: [])
    }

    private func layout(_ desktop: String, _ stages: [SavedStage]) -> Layout {
        Layout(savedAt: Date(timeIntervalSince1970: 0), stages: stages, desktop: desktop)
    }

    @Test func ordersByDesktopThenNaturalLabelOrder() {
        let desktops = [
            Desktop(key: "main", number: 1, spaceID: 1),
            Desktop(key: "second", number: 2, spaceID: 2),
        ]
        // Passed in a different order from `desktops`, with a layout for a desktop that no longer exists.
        let layouts = [
            layout("gone", [stage("Aardvark")]),
            layout("second", [stage("Zulu"), stage("beta")]),
            layout("main", [stage("Stage 10"), stage("Stage 9"), stage("alpha"), stage("No id", id: false), stage(nil)]),
        ]
        let labels = Actions.numbered(desktops: desktops, layouts: layouts).map(\.label)
        #expect(labels == ["alpha", "Stage 9", "Stage 10", "beta", "Zulu", "Aardvark"])
    }
}
