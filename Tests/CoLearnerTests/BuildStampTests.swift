import Foundation
import Testing
@testable import CoLearner

/// What About Co-learner says after the version: the commit and date scripts/build_app.sh stamped into Info.plist.
@Suite
struct BuildStampTests {
    @Test func namesTheCommitAndItsDate() {
        #expect(BuildStamp.text(["CoLearnerSourceCommit": "6dbe045", "CoLearnerSourceTime": 1794081203,
                                 "CoLearnerSourceDate": "2026-11-07"]) == "6dbe045, 2026-11-07")
        #expect(BuildStamp.text(["CoLearnerSourceCommit": "6dbe045+", "CoLearnerSourceDate": "2026-11-07"]) == "6dbe045+, 2026-11-07")
    }

    @Test func saysNothingWithoutAStamp() {
        #expect(BuildStamp.text([:]) == nil)
        #expect(BuildStamp.text(["CoLearnerSourceCommit": "unknown", "CoLearnerSourceTime": 0, "CoLearnerSourceDate": ""]) == nil)
        #expect(BuildStamp.text(["CoLearnerSourceCommit": ""]) == nil)
    }
}
