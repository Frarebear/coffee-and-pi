import Foundation

/// Probes this Mac + llama-fit-params to pick a context length that fits free memory.
enum HardwareContextFitter {
    struct HardwareInfo: Equatable {
        let totalMemoryBytes: UInt64
        let chipName: String

        var totalMemoryGB: Int {
            Int((Double(totalMemoryBytes) / 1_073_741_824.0).rounded())
        }

        var label: String {
            if chipName.isEmpty {
                return "\(totalMemoryGB) GB"
            }
            return "\(chipName) · \(totalMemoryGB) GB"
        }

        static func current() -> HardwareInfo {
            var size: UInt64 = 0
            var len = MemoryLayout<UInt64>.size
            sysctlbyname("hw.memsize", &size, &len, nil, 0)

            var brand = [CChar](repeating: 0, count: 256)
            var brandLen = brand.count
            sysctlbyname("machdep.cpu.brand_string", &brand, &brandLen, nil, 0)
            let chip = String(cString: brand).trimmingCharacters(in: .whitespacesAndNewlines)

            // Prefer marketing chip name when brand_string is empty/generic on Apple Silicon.
            let chipName: String = {
                if !chip.isEmpty { return chip }
                var model = [CChar](repeating: 0, count: 64)
                var modelLen = model.count
                sysctlbyname("hw.model", &model, &modelLen, nil, 0)
                return String(cString: model)
            }()

            return HardwareInfo(totalMemoryBytes: size, chipName: chipName)
        }
    }

    /// Run `llama-fit-params` and return the fitted `-c` value when available.
    static func fittedContext(
        modelPath: String?,
        hfRepo: String?,
        cacheTypeK: String,
        cacheTypeV: String,
        fitCtxMin: Int = 4096,
        fitTargetMiB: Int = 2048
    ) async -> Int? {
        let binary = resolveFitBinary()
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }

        var args: [String] = [
            "-ngl", "all",
            "-fa", "on",
            "-ctk", cacheTypeK,
            "-ctv", cacheTypeV,
            "-np", "1",
            "--fit", "on",
            "--fit-ctx", String(fitCtxMin),
            "--fit-target", String(fitTargetMiB),
        ]
        if let modelPath, FileManager.default.fileExists(atPath: modelPath) {
            args += ["-m", modelPath]
        } else if let hfRepo, !hfRepo.isEmpty {
            args += ["-hf", hfRepo]
        } else {
            return nil
        }

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = args
                proc.environment = [
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                    "HOME": NSHomeDirectory(),
                ]
                let out = Pipe()
                let err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: parseFittedCtx(from: text))
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Heuristic fallback when fit-params isn't available: leave headroom for weights + OS.
    static func heuristicContext(modelBytes: UInt64?, cacheTypeK: String) -> Int {
        let hw = HardwareInfo.current()
        let total = Double(hw.totalMemoryBytes)
        let model = Double(modelBytes ?? 0)
        // Keep ~6 GB for OS/UI + activations; KV gets the rest.
        let budget = max(0, total - model - 6_000_000_000)
        let bytesPerToken: Double = {
            // Rough KV cost per token for a ~12B class model; scale mildly with quant.
            // q8_0 ≈ baseline, q4 ≈ ~0.55x, f16 ≈ 2x
            switch cacheTypeK.lowercased() {
            case "f16", "bf16": return 1_200_000
            case "f32": return 2_400_000
            case "q4_0", "q4_1", "iq4_nl": return 350_000
            case "q5_0", "q5_1": return 450_000
            default: return 600_000 // q8_0-ish
            }
        }()
        let raw = Int(budget / max(bytesPerToken, 1))
        let snapped = LocalModelProfile.ctxSizes.reversed().first(where: { $0 <= raw }) ?? 4096
        return max(4096, snapped)
    }

    static func parseFittedCtx(from stdout: String) -> Int? {
        // stdout looks like: `-c 262144 -ngl -2`
        let parts = stdout.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let idx = parts.firstIndex(of: "-c"), idx + 1 < parts.count, let n = Int(parts[idx + 1]), n > 0 {
            return n
        }
        return nil
    }

    private static func resolveFitBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/llama-fit-params",
            "/usr/local/bin/llama-fit-params",
            NSHomeDirectory() + "/.local/bin/llama-fit-params",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/llama-fit-params"
    }
}
