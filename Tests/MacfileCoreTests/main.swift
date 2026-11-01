import Foundation
import MacfileCore

let tests = CoreTests()
let cases: [(String, () throws -> Void)] = [
  ("testCopyPreservesSourceAndVerifiesContent", tests.testCopyPreservesSourceAndVerifiesContent),
  ("testMoveThenUndo", tests.testMoveThenUndo),
  ("testDuplicateInSameFolder", tests.testDuplicateInSameFolder),
  (
    "testReplaceKeepsOriginalAndUndoRestoresBoth", tests.testReplaceKeepsOriginalAndUndoRestoresBoth
  ),
  ("testConflictPolicies", tests.testConflictPolicies),
  ("testUndoRefusesExternalContentChange", tests.testUndoRefusesExternalContentChange),
  ("testUndoRefusesRecreatedFileAtSamePath", tests.testUndoRefusesRecreatedFileAtSamePath),
  (
    "testRejectsSelfAndDescendantIncludingSymlinkParent",
    tests.testRejectsSelfAndDescendantIncludingSymlinkParent
  ),
  ("testCopiesSymlinkWithoutFollowingIt", tests.testCopiesSymlinkWithoutFollowingIt),
  ("testDirectoryCopyPreservesNestedData", tests.testDirectoryCopyPreservesNestedData),
  (
    "testCancellationRollsBackStagingAndPreservesSource",
    tests.testCancellationRollsBackStagingAndPreservesSource
  ),
  ("testRenameSwapAndCycle", tests.testRenameSwapAndCycle),
  ("testRenameCollisionMakesNoChanges", tests.testRenameCollisionMakesNoChanges),
  ("testCaseOnlyRename", tests.testCaseOnlyRename),
  ("testRenameRulesAndInvalidNames", tests.testRenameRulesAndInvalidNames),
  ("testTrashAndRestoreWithinFixture", tests.testTrashAndRestoreWithinFixture),
  ("testCreateFolderUndoRefusesNewContents", tests.testCreateFolderUndoRefusesNewContents),
  (
    "testAllLayoutsCoverSpaceWithoutOverlapAndCanSplit",
    tests.testAllLayoutsCoverSpaceWithoutOverlapAndCanSplit
  ),
  ("testSplitAddRemoveAndStateRoundTrip", tests.testSplitAddRemoveAndStateRoundTrip),
  ("testThirtyTwoPaneStateNoHardLimit", tests.testThirtyTwoPaneStateNoHardLimit),
  ("testUndoJournalSurvivesRestart", tests.testUndoJournalSurvivesRestart),
  (
    "testCopyPreservesPermissionsAndExtendedAttributes",
    tests.testCopyPreservesPermissionsAndExtendedAttributes
  ),
  (
    "testSourceMutationIsDetectedWithoutDeletingSource",
    tests.testSourceMutationIsDetectedWithoutDeletingSource
  ),
  ("testCrossVolumeMoveAndUndo", tests.testCrossVolumeMoveAndUndo),
  ("testCrossVolumeMoveThroughSymlinkAndUndo", tests.testCrossVolumeMoveThroughSymlinkAndUndo),
]
print("Layout presets: \(LayoutPreset.all.count)")
var skipped = 0
for (name, run) in cases {
  let before = failures
  var skipReason: String?
  do {
    try tests.setUpWithError()
    try run()
  } catch let error as TestSkipped {
    skipped += 1
    skipReason = error.reason
  } catch { fail("\(name): \(error)") }
  do { try tests.tearDownWithError() } catch { fail("cleanup: \(error)") }
  if let skipReason {
    print("SKIP \(name): \(skipReason)")
  } else {
    print("\(failures == before ? "PASS" : "FAIL") \(name)")
  }
}
print("\(cases.count) test cases, \(failures) failures, \(skipped) skipped")
exit(failures == 0 ? 0 : 1)
