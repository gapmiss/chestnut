import Foundation

/// Every plugin process running right now, so the app can answer three
/// questions it could not answer before: is anything working (the chewing
/// pose), what is working (the Running Plugins submenu), and how do I stop it
/// (the cancel row, and the sweep on quit).
///
/// Before this existed, `runPlugin` turned the chewing pose on before a run and
/// off after it, per run. Nothing stops two plugins running at once — a drop
/// fires a detached `Task` with no guard — so the first run to finish stilled
/// the pet while the second was still working. With ten-second runs that window
/// was milliseconds wide and nobody saw it; with the timeout ceiling raised to
/// an hour it would be the normal case. The pose is now a question asked of this
/// type (`isEmpty`), not a pair of calls that can go out of order.
///
/// A leaked entry is worse than the bug it replaces: the pet chews forever
/// *and* the submenu offers to cancel a run that already exited. So
/// registration and removal are paired with `defer` at the one call site rather
/// than repeated down each exit path — see `AppDelegate.runPlugin`.
@MainActor
final class PluginRunRegistry {
    struct Run: Identifiable {
        let id: UUID
        /// The plugin's display name, for the submenu row. The plugin may be
        /// deleted or renamed mid-run; this is display text, never a lookup key.
        let name: String
        let started: Date
        let handle: PluginRunHandle
    }

    private(set) var runs: [Run] = []

    /// Fires on every register and remove. `AppDelegate` hangs the chewing pose
    /// off this so the pose cannot disagree with the registry.
    var onChange: (() -> Void)?

    var isEmpty: Bool { runs.isEmpty }
    var count: Int { runs.count }

    func register(name: String, handle: PluginRunHandle) -> UUID {
        let id = UUID()
        runs.append(Run(id: id, name: name, started: Date(), handle: handle))
        onChange?()
        return id
    }

    /// Removing an id that is not present is a no-op: the run may have been
    /// cancelled and removed already, and a `defer` that throws or traps here
    /// would be worse than a redundant call.
    func remove(_ id: UUID) {
        let before = runs.count
        runs.removeAll { $0.id == id }
        if runs.count != before { onChange?() }
    }

    /// Cancels one run. The entry stays until the run's own `defer` removes it,
    /// so the row survives the moment between the signal and the process
    /// actually dying — removing it here would leave the pet chewing with an
    /// empty submenu.
    @discardableResult
    func cancel(_ id: UUID) -> Bool {
        guard let run = runs.first(where: { $0.id == id }) else { return false }
        return run.handle.end(.cancelled)
    }

    /// Best-effort sweep for `applicationWillTerminate`. Signals every group and
    /// returns immediately — see the call site for why nothing here waits.
    func terminateAll() {
        for run in runs { run.handle.end(.cancelled) }
    }

    /// Whether the Running Plugins submenu appears at all.
    ///
    /// Hidden at zero, not shown empty or dimmed, following
    /// `PluginSaveRecord.showsUndoRow`: a row that can never be clicked teaches
    /// nothing, and unlike the Plugins submenu this one is not where the
    /// feature is discovered. Split out as a static function because
    /// `PetWindow` is outside the `make check` target and this rule is the one
    /// part of the submenu that can be checked.
    static func showsRunningSubmenu(runCount: Int) -> Bool { runCount > 0 }

    /// Second line of a submenu row: how long this run has been going.
    ///
    /// Coarse on purpose. The row exists to answer "is this the one I dropped
    /// ten minutes ago", not to time anything, and a seconds-precision label in
    /// a menu that does not redraw would be wrong the moment it appeared.
    static func elapsedLabel(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "running \(s)s" }
        let m = s / 60
        if m < 60 { return "running \(m)m" }
        return "running \(m / 60)h \(m % 60)m"
    }
}
