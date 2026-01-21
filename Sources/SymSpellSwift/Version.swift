//
// Version.swift
// SymSpellSwift
//
// Version information for the SymSpellSwift package.
//

import Foundation

/// Version information for SymSpellSwift package.
///
/// Use this to check the library version in your app:
/// ```swift
/// print("SymSpellSwift version: \(SymSpellSwiftVersion.current)")
/// // Output: SymSpellSwift version: 1.1.0
///
/// // Or get detailed info
/// print(SymSpellSwiftVersion.versionInfo)
/// ```
public struct SymSpellSwiftVersion {
    /// Major version number (breaking changes)
    public static let major = 1

    /// Minor version number (new features, backward compatible)
    public static let minor = 1

    /// Patch version number (bug fixes)
    public static let patch = 0

    /// Pre-release identifier (e.g., "beta.1", "rc.1", or nil for release)
    public static let prerelease: String? = nil

    /// Build metadata (optional)
    public static let buildMetadata: String? = nil

    /// Current version as a string (e.g., "1.1.0" or "1.1.0-beta.1")
    public static var current: String {
        var version = "\(major).\(minor).\(patch)"
        if let prerelease = prerelease {
            version += "-\(prerelease)"
        }
        if let build = buildMetadata {
            version += "+\(build)"
        }
        return version
    }

    /// Detailed version info string for debugging
    public static var versionInfo: String {
        return """
        SymSpellSwift v\(current)
        - Keyboard layouts: QWERTY, AZERTY, QWERTZ, Dvorak, Colemak
        - Features: Spell checking, Word segmentation (beam search), Compound correction
        - Memory mode: Low-memory (mmap) and Standard (in-memory)
        """
    }

    /// Check if current version is at least the specified version
    ///
    /// - Parameters:
    ///   - major: Required major version
    ///   - minor: Required minor version (default: 0)
    ///   - patch: Required patch version (default: 0)
    /// - Returns: true if current version >= specified version
    public static func isAtLeast(major: Int, minor: Int = 0, patch: Int = 0) -> Bool {
        if self.major != major { return self.major > major }
        if self.minor != minor { return self.minor > minor }
        return self.patch >= patch
    }

    /// Print version to console (convenience for debugging)
    public static func printVersion() {
        print("SymSpellSwift v\(current)")
    }
}

// MARK: - Convenience Extensions

extension LowMemorySymSpell {
    /// The version of SymSpellSwift being used
    public static var version: String {
        return SymSpellSwiftVersion.current
    }
}

extension SymSpell {
    /// The version of SymSpellSwift being used
    public static var version: String {
        return SymSpellSwiftVersion.current
    }
}
