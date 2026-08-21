internal import Environment

func environment(_ name: Swift.String) -> Swift.String? {
    Environment.read(name)
}
