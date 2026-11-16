import Foundation

/// Parsed Hugging Face model reference suitable for llama.cpp router download.
struct HuggingFaceModelRef: Hashable, Sendable {
    let owner: String
    let repo: String
    /// e.g. `Q4_K_M` — omit to let llama.cpp pick (defaults to Q4_K_M).
    var quantization: String?
    /// Exact filename override (from a blob/resolve URL).
    var filename: String?

    var repoID: String { "\(owner)/\(repo)" }

    /// Value passed to `POST /models` on the llama.cpp router.
    var routerModelID: String {
        if let filename, !filename.isEmpty {
            let stem = filename
                .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
            if let quant = Self.quantization(fromFilenameStem: stem) {
                return "\(repoID):\(quant)"
            }
        }
        if let quantization, !quantization.isEmpty {
            return "\(repoID):\(quantization.uppercased())"
        }
        return "\(repoID):Q4_K_M"
    }

    var shortPresetID: String {
        var base = repo
            .replacingOccurrences(of: "-GGUF", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_GGUF", with: "", options: .caseInsensitive)
            .lowercased()
        if let quantization {
            base += "-\(quantization.lowercased().replacingOccurrences(of: "_", with: "-"))"
        }
        let cleaned = base
            .map { ch -> Character in
                if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { return ch }
                return "-"
            }
        return String(cleaned)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    static func parse(_ raw: String) throws -> HuggingFaceModelRef {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HuggingFaceLink", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Paste a Hugging Face model link or owner/repo[:quant]",
            ])
        }

        // Bare `owner/repo` or `owner/repo:quant`
        if !trimmed.contains("://"), !trimmed.lowercased().contains("huggingface.co"), !trimmed.lowercased().contains("hf.co") {
            return try parseRepoSpec(trimmed)
        }

        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            throw NSError(domain: "HuggingFaceLink", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unrecognized Hugging Face URL",
            ])
        }
        guard host == "huggingface.co" || host == "www.huggingface.co" || host == "hf.co" || host == "www.hf.co" else {
            throw NSError(domain: "HuggingFaceLink", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Link must be a huggingface.co / hf.co URL",
            ])
        }

        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw NSError(domain: "HuggingFaceLink", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "URL must include owner/repo",
            ])
        }

        let owner = parts[0]
        let repo = parts[1]
        var filename: String?
        var quantization: String?

        // /owner/repo/blob/main/file.gguf  or  /resolve/main/file.gguf
        if parts.count >= 5, parts[2] == "blob" || parts[2] == "resolve" {
            let file = parts.dropFirst(4).joined(separator: "/")
            if file.lowercased().hasSuffix(".gguf") {
                filename = (file as NSString).lastPathComponent
                let stem = filename!.replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
                quantization = Self.quantization(fromFilenameStem: stem)
            }
        }

        // Query ?quantization=Q4_K_M (rare but handy)
        if quantization == nil,
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let q = items.first(where: { $0.name.lowercased() == "quantization" || $0.name.lowercased() == "quant" })?.value,
           !q.isEmpty {
            quantization = q.uppercased()
        }

        return HuggingFaceModelRef(owner: owner, repo: repo, quantization: quantization, filename: filename)
    }

    private static func parseRepoSpec(_ raw: String) throws -> HuggingFaceModelRef {
        let pieces = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let id = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let quant = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : nil
        let idParts = id.split(separator: "/").map(String.init)
        guard idParts.count == 2, !idParts[0].isEmpty, !idParts[1].isEmpty else {
            throw NSError(domain: "HuggingFaceLink", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Expected owner/repo or owner/repo:QUANT",
            ])
        }
        return HuggingFaceModelRef(
            owner: idParts[0],
            repo: idParts[1],
            quantization: quant?.isEmpty == false ? quant : nil,
            filename: nil
        )
    }

    private static func quantization(fromFilenameStem stem: String) -> String? {
        // Match trailing quant tags like Q4_K_M, IQ4_XS, BF16, F16, UD-Q4_K_M
        let pattern = #"(?:^|[-_.])((?:UD-)?(?:IQ\d(?:_[A-Z0-9]+)+|Q\d(?:_[A-Z0-9]+)+|BF16|F16|F32|MXFP\d(?:_[A-Z0-9]+)*))$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let match = regex.firstMatch(in: stem, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: stem)
        else { return nil }
        return String(stem[r]).uppercased()
    }
}
