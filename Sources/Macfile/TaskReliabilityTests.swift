import AppKit
import MacfileCore

extension UITestRunner {
  func addTaskReliabilityTests(_ w: WorkspaceController) {
    var failedTasks: TaskCenter!
    var failedWorkStarted = false
    steps.append(
      (
        "task-initialization-failure-start",
        { [self] in
          let folder = root.appendingPathComponent("task-failure-" + UUID().uuidString)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          try Data("occupied journal path".utf8).write(to: folder.appendingPathComponent("journal"))
          failedTasks = TaskCenter(folder: folder)
          taskReliabilityCenters.append(failedTasks)
          failedTasks.perform(title: "初始化失败验证", total: 1) { _, _ in failedWorkStarted = true }
        }
      ))
    steps.append(
      (
        "task-initialization-failure-is-not-cancellation",
        { [self] in
          try require(
            !failedWorkStarted && failedTasks.records.first?.status == .failed
              && failedTasks.records.first?.errors.isEmpty == false, "初始化错误被误记为取消或未保留原因")
        }
      ))
    var cancelledTasks: TaskCenter!
    let cancelledID = UUID()
    var cancelledWorkStarted = false
    steps.append(
      (
        "task-explicit-cancellation-start",
        { [self] in
          cancelledTasks = TaskCenter(
            folder: root.appendingPathComponent("task-cancel-" + UUID().uuidString))
          taskReliabilityCenters.append(cancelledTasks)
          let hold = DispatchSemaphore(value: 0)
          cancelledTasks.submit(title: "隔离队列占位", total: 0) { _, _ in
            _ = hold.wait(timeout: .now() + 5)
          }
          cancelledTasks.submit(id: cancelledID, title: "待取消任务", total: 1) { _, _ in
            cancelledWorkStarted = true
          }
          cancelledTasks.cancel(cancelledID)
          hold.signal()
        }
      ))
    steps.append(
      (
        "task-explicit-cancellation-remains-cancelled",
        { [self] in
          try require(
            !cancelledWorkStarted
              && cancelledTasks.records.first(where: { $0.id == cancelledID })?.status
                == .cancelled,
            "显式取消未保留取消状态")
        }
      ))
    let chainFolder = root.appendingPathComponent("task-chain-" + UUID().uuidString)
    let copied = chainFolder.appendingPathComponent("copy.txt")
    var chainTasks: TaskCenter!
    var originalTasks: [TaskRecord] = []
    steps.append(
      (
        "task-undo-chain-start",
        { [self] in
          try FileManager.default.createDirectory(
            at: chainFolder, withIntermediateDirectories: true)
          let source = chainFolder.appendingPathComponent("source.txt")
          let moved = chainFolder.appendingPathComponent("moved.txt")
          try Data("isolated task chain".utf8).write(to: source)
          let engine = try FileOperations(
            journalDirectory: chainFolder.appendingPathComponent("journal"))
          let copy = try engine.transfer(source, to: copied, kind: .copy, conflict: .ask)!
          let move = try engine.transfer(copied, to: moved, kind: .move, conflict: .ask)!
          var copyTask = TaskRecord(title: "复制", total: 1)
          copyTask.status = .completed
          copyTask.completed = 1
          copyTask.receipts = [copy]
          var moveTask = TaskRecord(title: "移动", total: 1)
          moveTask.status = .completed
          moveTask.completed = 1
          moveTask.receipts = [move]
          originalTasks = [moveTask, copyTask]
          chainTasks = TaskCenter(folder: chainFolder)
          taskReliabilityCenters.append(chainTasks)
          chainTasks.records = originalTasks
          chainTasks.changed()
          chainTasks.undo(moveTask.id)
        }
      ))
    steps.append(
      (
        "task-undo-chain-refreshes-history-and-journal",
        { [self] in
          let moveTask = originalTasks[0]
          let copyTask = originalTasks[1]
          let engine = try FileOperations(
            journalDirectory: chainFolder.appendingPathComponent("journal"))
          let signature = try engine.digest(copied, metadata: true)
          try require(
            chainTasks.records.first(where: { $0.id == moveTask.id })?.status == .undone
              && chainTasks.records.first(where: { $0.id == copyTask.id })?.receipts.first?
                .signature == signature,
            "撤销后任务中心未更新因果链中的旧收据")
          // Simulate a tasks.json snapshot older than the completed journal writes.
          try JSONEncoder().encode(originalTasks).write(
            to: chainFolder.appendingPathComponent("tasks.json"))
          let restarted = TaskCenter(folder: chainFolder)
          try require(
            restarted.records.first(where: { $0.id == moveTask.id })?.status == .undone
              && restarted.records.first(where: { $0.id == copyTask.id })?.receipts.first?.signature
                == signature,
            "重启后未从 journal 恢复更新的收据")
        }
      ))
    var recoveredChains: [(TaskCenter, URL, URL, URL)] = []
    steps.append(
      (
        "task-journal-only-move-and-rename-start",
        { [self] in
          for rename in [false, true] {
            let folder = root.appendingPathComponent("task-journal-only-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("source.txt")
            let middle = folder.appendingPathComponent("middle.txt")
            let target = folder.appendingPathComponent("target.txt")
            try Data("journal recovery".utf8).write(to: source)
            let engine = try FileOperations(
              journalDirectory: folder.appendingPathComponent("journal"))
            if rename {
              try engine.renameBatch([(source, middle.lastPathComponent)], didComplete: { _ in })
              try engine.renameBatch([(middle, target.lastPathComponent)], didComplete: { _ in })
            } else {
              _ = try engine.transfer(source, to: middle, kind: .move, conflict: .ask)
              _ = try engine.transfer(middle, to: target, kind: .move, conflict: .ask)
            }
            let recovered = TaskCenter(folder: folder)
            taskReliabilityCenters.append(recovered)
            try require(
              recovered.records.count == 2
                && recovered.records[0].receipts.first?.destination == target.path,
              "仅有 journal 时未按原操作分组和时间恢复")
            recoveredChains.append((recovered, source, middle, target))
            recovered.undo(recovered.records[0].id)
          }
        }
      ))
    steps.append(
      (
        "task-journal-only-undo-previous-operation",
        { [self] in
          for (tasks, _, middle, target) in recoveredChains {
            try require(FileOperations.exists(middle) && !FileOperations.exists(target), "最新操作未撤销")
            let previous = tasks.records.first { $0.receipts.contains { !$0.undone } }!
            tasks.undo(previous.id)
          }
        }
      ))
    steps.append(
      (
        "task-journal-only-recovery-undo-order",
        { [self] in
          for (tasks, source, middle, target) in recoveredChains {
            try require(
              tasks.records.flatMap(\.receipts).allSatisfy(\.undone)
                && FileOperations.exists(source) && !FileOperations.exists(middle)
                && !FileOperations.exists(target),
              "仅有 journal 时没有按逆序完成移动或重命名撤销链")
          }
        }
      ))
    var swapTasks: TaskCenter!
    let swapFolder = root.appendingPathComponent("task-rename-batch-" + UUID().uuidString)
    steps.append(
      (
        "task-journal-rename-cycle-start",
        { [self] in
          try FileManager.default.createDirectory(at: swapFolder, withIntermediateDirectories: true)
          let a = swapFolder.appendingPathComponent("a")
          let b = swapFolder.appendingPathComponent("b")
          try Data("A".utf8).write(to: a)
          try Data("B".utf8).write(to: b)
          let engine = try FileOperations(
            journalDirectory: swapFolder.appendingPathComponent("journal"))
          try engine.renameBatch([(a, "b"), (b, "a")], didComplete: { _ in })
          swapTasks = TaskCenter(folder: swapFolder)
          taskReliabilityCenters.append(swapTasks)
          try require(
            swapTasks.records.count == 1 && swapTasks.records[0].receipts.count == 2,
            "同批循环重命名未恢复为一个原子任务")
          swapTasks.undo(swapTasks.records[0].id)
        }
      ))
    steps.append(
      (
        "task-journal-rename-cycle-restored",
        { [self] in
          let a = try String(contentsOf: swapFolder.appendingPathComponent("a"), encoding: .utf8)
          let b = try String(contentsOf: swapFolder.appendingPathComponent("b"), encoding: .utf8)
          try require(
            a == "A" && b == "B" && swapTasks.records.flatMap(\.receipts).allSatisfy(\.undone),
            "journal 恢复的循环重命名未完整撤销")
        }
      ))
    var legacyTasks: TaskCenter!
    let legacyFolder = root.appendingPathComponent("task-legacy-rename-" + UUID().uuidString)
    steps.append(("task-legacy-journal-rename-cycle-start", { [self] in
      try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
      let a = legacyFolder.appendingPathComponent("a"), b = legacyFolder.appendingPathComponent("b")
      try Data("A".utf8).write(to: a)
      try Data("B".utf8).write(to: b)
      let engine = try FileOperations(journalDirectory: legacyFolder.appendingPathComponent("journal"))
      var receipts: [OperationReceipt] = []
      try engine.renameBatch([(a, "b"), (b, "a")]) { receipts.append($0) }
      for var receipt in receipts {
        receipt.renameBatchID = nil
        receipt.undoPredecessors = nil
        try engine.saveReceipt(receipt)
      }
      legacyTasks = TaskCenter(folder: legacyFolder)
      taskReliabilityCenters.append(legacyTasks)
      try require(legacyTasks.records.count == 1 && legacyTasks.records[0].receipts.count == 2,
        "旧版无批次标识的循环重命名被拆开")
      legacyTasks.undo(legacyTasks.records[0].id)
    }))
    steps.append(("task-legacy-journal-rename-cycle-restored", { [self] in
      let a = try String(contentsOf: legacyFolder.appendingPathComponent("a"), encoding: .utf8)
      let b = try String(contentsOf: legacyFolder.appendingPathComponent("b"), encoding: .utf8)
      try require(a == "A" && b == "B" && legacyTasks.records.flatMap(\.receipts).allSatisfy(\.undone),
        "旧版 journal 循环重命名未保持可撤销")
    }))
  }
}
