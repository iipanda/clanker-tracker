import Foundation
import Testing
@testable import ClankerCore

@Suite struct CommandRunnerTests {
    @Test func capturesOutputAndRejectsFailedCommands() async {
        #expect(await ClaudeUsageAPI.run("/usr/bin/printf", ["credential-output"], timeout: 2) == Data("credential-output".utf8))
        #expect(await ClaudeUsageAPI.run("/bin/sh", ["-c", "printf partial; exit 1"], timeout: 2) == nil)
        #expect(await ClaudeUsageAPI.run("/nonexistent/clanker-test", [], timeout: 2) == nil)
    }

    @Test func drainsMoreThanAPipeBuffer() async {
        let data = await ClaudeUsageAPI.run("/bin/sh", ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null"], timeout: 3)
        #expect(data?.count == 262_144)
        #expect(data?.allSatisfy { $0 == 0 } == true)
    }

    @Test func timeoutDoesNotWaitForSigtermOrInheritedStdout() async {
        let clock = ContinuousClock()
        // The shell ignores TERM and a child holds stdout open. Neither may extend the deadline.
        let start = clock.now
        let result = await ClaudeUsageAPI.run("/bin/sh", ["-c", "trap '' TERM; sleep 2 & wait"], timeout: 0.1)
        #expect(result == nil)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func parentExitDoesNotWaitForeverForDescendantsStdout() async {
        let clock = ContinuousClock(), start = clock.now
        let result = await ClaudeUsageAPI.run("/bin/sh", ["-c", "sleep 2 & exit 0"], timeout: 0.1)
        #expect(result == nil)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }
}
