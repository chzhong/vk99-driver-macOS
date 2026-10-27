import Foundation

public struct SettingOption: Equatable {
    public let group: String
    public let label: String
    public let rawValue: String?
    public let evidence: String?
}

public struct SettingsCatalog {
    public let options: [SettingOption]

    public init(yaml: String) throws {
        struct Draft {
            var group: String
            var label: String
            var rawValue: String?
            var evidence: String?
        }
        var currentGroup: String?
        var draft: Draft?
        var parsed: [SettingOption] = []

        func scalar(_ value: Substring) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed == "null" || trimmed.isEmpty { return nil }
            if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed
        }

        func finish(_ draft: Draft?, into options: inout [SettingOption]) throws {
            guard let draft else { return }
            guard !draft.label.isEmpty else { throw CatalogError.invalid("Empty option label") }
            options.append(SettingOption(group: draft.group, label: draft.label,
                                         rawValue: draft.rawValue, evidence: draft.evidence))
        }

        for (index, sourceLine) in yaml.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = sourceLine.trimmingCharacters(in: .newlines)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && line.hasSuffix(":") {
                try finish(draft, into: &parsed)
                draft = nil
                currentGroup = String(line.dropLast())
            } else if line.hasPrefix("  - label: ") {
                try finish(draft, into: &parsed)
                guard let currentGroup, let label = scalar(line.dropFirst("  - label: ".count)) else {
                    throw CatalogError.invalid("Invalid label at line \(index + 1)")
                }
                draft = Draft(group: currentGroup, label: label, rawValue: nil, evidence: nil)
            } else if line.hasPrefix("    raw: ") {
                guard draft != nil else { throw CatalogError.invalid("Raw value without option at line \(index + 1)") }
                draft?.rawValue = scalar(line.dropFirst("    raw: ".count))
            } else if line.hasPrefix("    evidence: ") {
                guard draft != nil else { throw CatalogError.invalid("Evidence without option at line \(index + 1)") }
                draft?.evidence = scalar(line.dropFirst("    evidence: ".count))
            } else {
                throw CatalogError.invalid("Unsupported YAML at line \(index + 1)")
            }
        }
        try finish(draft, into: &parsed)
        guard !parsed.isEmpty else { throw CatalogError.invalid("No settings found") }
        self.options = parsed
    }

    public func options(in group: String) -> [SettingOption] {
        options.filter { $0.group == group }
    }
}

public enum CatalogError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        if case .invalid(let detail) = self { return detail }
        return "Invalid settings catalog"
    }
}
