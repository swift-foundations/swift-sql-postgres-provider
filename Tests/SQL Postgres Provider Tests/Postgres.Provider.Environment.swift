internal import Environment

/// Reads a process-environment variable through the Institute's `Environment` package, so no
/// test file names a platform module.
///
/// Isolated to its own file: `Environment` re-exports the Institute's own `String`, which is
/// `~Copyable` and would shadow `Swift.String` for every declaration in a file that imports it.
/// Confining the import here keeps the test files on the standard `String`.
func environment(_ name: Swift.String) -> Swift.String? {
    Environment.read(name)
}
