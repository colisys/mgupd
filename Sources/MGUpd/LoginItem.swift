import Foundation

/// Launch-at-login through a per-user LaunchAgent plist.
///
/// The plist is only written or removed, never bootstrapped: launchd loads
/// `~/Library/LaunchAgents` at the next login. Bootstrapping with `RunAtLoad`
/// would start a second instance immediately, and `bootout` would kill the
/// running app because launchd owns it.
enum LoginItem {
    static let label = "local.mgupd.MGUpd.login"

    static func plistURL(directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent("\(label).plist")
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    /// No `KeepAlive`: quitting MGUpd must stay quit until the next login.
    static func plist(executable: String) throws -> Data {
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// True only when the plist exists and points at `executable`, so a moved
    /// or rebuilt app shows as off instead of silently launching nothing.
    static func isEnabled(executable: String?, directory: URL = defaultDirectory) -> Bool {
        guard let executable,
              let data = try? Data(contentsOf: plistURL(directory: directory)),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String] else { return false }
        return arguments.first == executable
    }

    static func setEnabled(_ enabled: Bool, executable: String?, directory: URL = defaultDirectory) throws {
        let url = plistURL(directory: directory)
        if enabled {
            guard let executable, executable.hasPrefix("/") else {
                throw CocoaError(.fileNoSuchFile)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try plist(executable: executable).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
