import ClankerCore
import Foundation
import Testing
@testable import ClankerTracker

@Suite @MainActor struct InstalledAgentsTests {
    @Test func detectsExecutablesOutsideGUIPath() {
        let files: Set<String> = ["/test/.local/bin/claude", "/opt/homebrew/bin/codex", "/test/.local/bin/agent"]
        let detected = InstalledAgents.detect(home: URL(fileURLWithPath: "/test"), environment: [:],
                                              executable: { files.contains($0) }, appExists: { _ in false })
        #expect(detected == Set(Tool.allCases))
    }

    @Test func detectsDesktopApplications() {
        let detected = InstalledAgents.detect(home: URL(fileURLWithPath: "/test"), environment: [:],
                                              executable: { _ in false },
                                              appExists: { ["/Applications/Codex.app", "/test/Applications/Cursor.app"].contains($0) })
        #expect(detected == [.codex, .cursor])
    }

    @Test func noExecutableOrAppMeansNoInstalledAgent() {
        #expect(InstalledAgents.detect(environment: [:], executable: { _ in false }, appExists: { _ in false }).isEmpty)
    }

    @Test func detectsCustomPathAndCursorAgentAlias() {
        #expect(InstalledAgents.detect(environment: ["PATH": "/custom/bin"],
                                      executable: { $0 == "/custom/bin/cursor-agent" }, appExists: { _ in false }) == [.cursor])
    }
}
