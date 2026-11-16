import Foundation

/// Talks to a `pi --mode rpc` child process over JSONL stdin/stdout.
actor PiRPCClient {
    enum ClientError: LocalizedError {
        case notRunning
        case piNotFound
        case failed(String)
        case timeout
        case exited(Int32)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "Pi RPC is not running"
            case .piNotFound: return "pi binary not found in PATH"
            case .failed(let s): return s
            case .timeout: return "Timed out waiting for Pi RPC response"
            case .exited(let code): return "Pi RPC exited (code \(code))"
            }
        }
    }

    private var process: Process?
    // Retain pipes for process lifetime — releasing them can close child fds.
    private var inPipe: Pipe?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var stdinHandle: FileHandle?
    private var pending: [String: CheckedContinuation<RPCResponse, Error>] = [:]
    private var eventHandler: (@Sendable (RPCEvent) -> Void)?
    private var exitHandler: (@Sendable (Int32) -> Void)?
    private var lastStderr = ""
    private let outBuffer = OutBuffer()

    var isRunning: Bool { process?.isRunning == true }
    var recentStderr: String { lastStderr }

    func setEventHandler(_ handler: (@Sendable (RPCEvent) -> Void)?) {
        eventHandler = handler
    }

    func setExitHandler(_ handler: (@Sendable (Int32) -> Void)?) {
        exitHandler = handler
    }

    func start(
        cwd: String = NSHomeDirectory(),
        provider: String? = nil,
        model: String? = nil,
        thinking: ThinkingLevel? = nil,
        appendSystemPrompt: String? = nil,
        sessionDir: String? = nil,
        sessionID: String? = nil
    ) async throws {
        if isRunning { return }
        guard let piURL = Self.resolvePiBinary() else { throw ClientError.piNotFound }

        let proc = Process()
        proc.executableURL = piURL
        var args = ["--mode", "rpc"]
        if let sessionDir {
            args += ["--session-dir", sessionDir]
        }
        if let sessionID {
            args += ["--session-id", sessionID]
        } else {
            args += ["--no-session"]
        }
        if let provider { args += ["--provider", provider] }
        if let model {
            if let thinking {
                args += ["--model", "\(model):\(thinking.rawValue)"]
            } else {
                args += ["--model", model]
            }
        }
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty {
            args += ["--append-system-prompt", appendSystemPrompt]
        }
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = [
            "PATH": "/opt/homebrew/bin:\(NSHomeDirectory())/.npm-global/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "TERM": "dumb",
        ]

        let inP = Pipe()
        let outP = Pipe()
        let errP = Pipe()
        proc.standardInput = inP
        proc.standardOutput = outP
        proc.standardError = errP

        proc.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { await self?.noteExit(code) }
        }

        // Non-blocking pipe reads — never use availableData inside Swift Tasks
        // (it blocks the cooperative thread pool and deadlocks RPC waiters).
        let outHandle = outP.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.consumeStdout(chunk) }
        }
        let errHandle = errP.fileHandleForReading
        errHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.consumeStderr(chunk) }
        }

        try proc.run()

        process = proc
        inPipe = inP
        outPipe = outP
        errPipe = errP
        stdinHandle = inP.fileHandleForWriting
        lastStderr = ""

        // Prove the RPC channel is alive before callers send prompts.
        let ready = try await send(["type": "get_state"], timeout: 15)
        guard ready.success else {
            throw ClientError.failed(ready.error ?? "Pi RPC failed get_state")
        }
    }

    func stop() {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        for (_, cont) in pending { cont.resume(throwing: ClientError.notRunning) }
        pending.removeAll()
        try? stdinHandle?.close()
        process?.terminate()
        process = nil
        stdinHandle = nil
        inPipe = nil
        outPipe = nil
        errPipe = nil
    }

    func getAvailableModels() async throws -> [PiModel] {
        let res = try await send(["type": "get_available_models"])
        guard res.success else { throw ClientError.failed(res.error ?? "get_available_models failed") }
        return res.models
    }

    func getMessages() async throws -> [ChatMessage] {
        let res = try await send(["type": "get_messages"])
        guard res.success else { throw ClientError.failed(res.error ?? "get_messages failed") }
        return res.messages
    }

    /// Extension / prompt / skill slash commands (not TUI builtins).
    func getCommands() async throws -> [SlashCommand] {
        let res = try await send(["type": "get_commands"])
        guard res.success else { throw ClientError.failed(res.error ?? "get_commands failed") }
        return res.commands
    }

    func compact(customInstructions: String? = nil) async throws {
        var body: [String: Any] = ["type": "compact"]
        if let customInstructions, !customInstructions.isEmpty {
            body["customInstructions"] = customInstructions
        }
        let res = try await send(body, timeout: 120)
        guard res.success else { throw ClientError.failed(res.error ?? "compact failed") }
    }

    func setModel(provider: String, modelId: String) async throws {
        let res = try await send([
            "type": "set_model",
            "provider": provider,
            "modelId": modelId,
        ])
        guard res.success else { throw ClientError.failed(res.error ?? "set_model failed") }
    }

    func setThinkingLevel(_ level: ThinkingLevel) async throws {
        let res = try await send([
            "type": "set_thinking_level",
            "level": level.rawValue,
        ])
        guard res.success else { throw ClientError.failed(res.error ?? "set_thinking_level failed") }
    }

    func setAutoCompaction(_ enabled: Bool) async throws {
        let res = try await send([
            "type": "set_auto_compaction",
            "enabled": enabled,
        ])
        guard res.success else { throw ClientError.failed(res.error ?? "set_auto_compaction failed") }
    }

    func prompt(_ message: String) async throws {
        let res = try await send(["type": "prompt", "message": message], timeout: 60)
        guard res.success else { throw ClientError.failed(res.error ?? "prompt failed") }
    }

    func abort() async throws {
        let res = try await send(["type": "abort"])
        guard res.success else { throw ClientError.failed(res.error ?? "abort failed") }
    }

    func newSession() async throws {
        let res = try await send(["type": "new_session"])
        guard res.success else { throw ClientError.failed(res.error ?? "new_session failed") }
    }

    // MARK: - Internals

    private func consumeStdout(_ chunk: Data) async {
        let lines = await outBuffer.append(chunk)
        for line in lines {
            handleLine(line)
        }
    }

    private func consumeStderr(_ chunk: Data) {
        if let s = String(data: chunk, encoding: .utf8), !s.isEmpty {
            lastStderr = String((lastStderr + s).suffix(4000))
        }
    }

    private func noteExit(_ code: Int32) {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        for (_, cont) in pending {
            cont.resume(throwing: ClientError.exited(code))
        }
        pending.removeAll()
        process = nil
        stdinHandle = nil
        exitHandler?(code)
    }

    private func send(_ body: [String: Any], timeout: TimeInterval = 30) async throws -> RPCResponse {
        guard let handle = stdinHandle, process?.isRunning == true else {
            throw ClientError.notRunning
        }
        let id = UUID().uuidString
        var payload = body
        payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard var line = String(data: data, encoding: .utf8) else {
            throw ClientError.failed("Could not encode RPC command")
        }
        line.append("\n")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RPCResponse, Error>) in
            pending[id] = cont
            handle.write(Data(line.utf8))
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let stuck = self.pending.removeValue(forKey: id) {
                    stuck.resume(throwing: ClientError.timeout)
                }
            }
        }
    }

    private func handleLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""

        if type == "response" {
            let id = obj["id"] as? String
            let response = RPCResponse.parse(obj)
            if let id, let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: response)
            }
            return
        }

        eventHandler?(RPCEvent.parse(obj))
    }

    private static func resolvePiBinary() -> URL? {
        let candidates = [
            NSHomeDirectory() + "/.npm-global/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

// MARK: - Types

struct RPCResponse: Sendable {
    let id: String?
    let command: String
    let success: Bool
    let error: String?
    let models: [PiModel]
    let messages: [ChatMessage]

    static func parse(_ obj: [String: Any]) -> RPCResponse {
        var models: [PiModel] = []
        var messages: [ChatMessage] = []
        if let data = obj["data"] as? [String: Any],
           let rows = data["models"] as? [[String: Any]] {
            models = rows.compactMap(PiModel.fromRPC)
        } else if let data = obj["data"] as? [String: Any],
                  let provider = data["provider"] as? String,
                  let modelId = (data["id"] as? String) ?? (data["modelId"] as? String) {
            models = [PiModel(provider: provider, modelId: modelId, name: data["name"] as? String, reasoning: data["reasoning"] as? Bool)]
        }
        if let data = obj["data"] as? [String: Any],
           let rows = data["messages"] as? [[String: Any]] {
            messages = rows.compactMap(ChatMessage.fromRPC)
        }
        return RPCResponse(
            id: obj["id"] as? String,
            command: obj["command"] as? String ?? "",
            success: obj["success"] as? Bool ?? false,
            error: obj["error"] as? String,
            models: models,
            messages: messages
        )
    }
}

extension ChatMessage {
    static func fromRPC(_ row: [String: Any]) -> ChatMessage? {
        let roleRaw = (row["role"] as? String) ?? "assistant"
        guard let role = Role(rawValue: roleRaw) else { return nil }
        let id = (row["id"] as? String) ?? UUID().uuidString
        var text = ""
        var thinking = ""
        if let s = row["content"] as? String {
            text = s
        } else if let parts = row["content"] as? [[String: Any]] {
            var textParts: [String] = []
            var thinkingParts: [String] = []
            for part in parts {
                let type = part["type"] as? String
                if type == "text", let t = part["text"] as? String {
                    textParts.append(t)
                } else if type == "thinking", let t = part["thinking"] as? String {
                    thinkingParts.append(t)
                } else if type == "toolCall" || type == "tool_use" {
                    let name = part["name"] as? String ?? "tool"
                    textParts.append("[\(name)]")
                }
            }
            text = textParts.joined(separator: "\n")
            thinking = thinkingParts.joined(separator: "\n")
        }
        return ChatMessage(
            id: id,
            role: role,
            text: text,
            thinkingText: thinking,
            isStreaming: false
        )
    }
}

struct RPCEvent: Sendable {
    let type: String
    let textDelta: String?
    let thinkingDelta: String?
    let phase: StreamPhase?
    let toolName: String?
    let isSettled: Bool
    let settledAborted: Bool
    let assistantFinalText: String?
    let assistantFinalThinking: String?
    /// User-facing failure from stream / message_end / retry.
    let streamError: String?
    /// Short status for retry chip, e.g. "Retrying 1/3…".
    let retryStatus: String?

    static func parse(_ obj: [String: Any]) -> RPCEvent {
        let type = obj["type"] as? String ?? ""
        let nested = (obj["assistantMessageEvent"] as? [String: Any])
            ?? (obj["event"] as? [String: Any])
        let nestedType = nested?["type"] as? String

        var textDelta: String?
        var thinkingDelta: String?
        var phase: StreamPhase?
        var toolName: String?
        var streamError: String?
        var retryStatus: String?
        var settledAborted = false

        switch type {
        case "agent_start", "turn_start":
            phase = .starting
        case "tool_execution_start":
            phase = .tooling
            toolName = obj["toolName"] as? String
        case "tool_execution_end":
            phase = .thinking
        case "auto_retry_start":
            phase = .retrying
            let attempt = obj["attempt"] as? Int ?? 1
            let maxAttempts = obj["maxAttempts"] as? Int
            var status = maxAttempts.map { "Retrying \(attempt)/\($0)…" } ?? "Retrying (\(attempt))…"
            if let err = obj["errorMessage"] as? String, !err.isEmpty {
                status += " — \(Self.shortError(err))"
            }
            retryStatus = status
        case "auto_retry_end":
            let success = obj["success"] as? Bool ?? false
            if success {
                phase = .thinking
            } else {
                let final = (obj["finalError"] as? String)
                    ?? (obj["errorMessage"] as? String)
                    ?? "Model request failed after retries"
                streamError = Self.humanize(final)
            }
        case "compaction_end":
            let aborted = obj["aborted"] as? Bool ?? false
            if let err = obj["errorMessage"] as? String, !err.isEmpty, !aborted {
                streamError = "Compaction failed — \(Self.humanize(err))"
            }
        case "message_update":
            switch nestedType {
            case "thinking_start", "thinking_delta":
                phase = .thinking
                if nestedType == "thinking_delta" {
                    thinkingDelta = nested?["delta"] as? String
                }
            case "text_start", "text_delta":
                phase = .responding
                if nestedType == "text_delta" {
                    textDelta = nested?["delta"] as? String
                }
            case "toolcall_start":
                phase = .tooling
                toolName = (nested?["toolName"] as? String) ?? (nested?["name"] as? String)
            case "error":
                streamError = Self.humanize(
                    (nested?["error"] as? String)
                        ?? (nested?["reason"] as? String)
                        ?? "Stream error"
                )
            default:
                break
            }
        case "message_start":
            if let message = obj["message"] as? [String: Any],
               (message["role"] as? String) == "assistant" {
                phase = .thinking
            }
        case "agent_settled":
            settledAborted = obj["aborted"] as? Bool ?? false
        default:
            break
        }

        if textDelta == nil, nestedType == "text_delta" {
            textDelta = nested?["delta"] as? String
            phase = phase ?? .responding
        }
        if thinkingDelta == nil, nestedType == "thinking_delta" {
            thinkingDelta = nested?["delta"] as? String
            phase = phase ?? .thinking
        }

        var finalText: String?
        var finalThinking: String?
        if type == "message_end" || type == "message",
           let message = obj["message"] as? [String: Any],
           (message["role"] as? String) == "assistant" {
            if let text = message["content"] as? String {
                finalText = text
            } else if let parts = message["content"] as? [[String: Any]] {
                finalText = parts.compactMap { part -> String? in
                    guard (part["type"] as? String) == "text" else { return nil }
                    return part["text"] as? String
                }.joined()
                finalThinking = parts.compactMap { part -> String? in
                    guard (part["type"] as? String) == "thinking" else { return nil }
                    return part["thinking"] as? String
                }.joined(separator: "\n")
            }

            let stop = message["stopReason"] as? String
            let errMsg = message["errorMessage"] as? String
            switch stop {
            case "error":
                streamError = Self.humanize(errMsg ?? "Model error")
            case "aborted":
                // Soft — user abort; only surface if we have a message.
                if let errMsg, !errMsg.isEmpty {
                    streamError = Self.humanize(errMsg)
                }
            case "length":
                streamError = Self.humanize(errMsg ?? "Hit the context or output limit")
            default:
                break
            }
        }

        return RPCEvent(
            type: type,
            textDelta: textDelta,
            thinkingDelta: thinkingDelta,
            phase: phase,
            toolName: toolName,
            isSettled: type == "agent_settled",
            settledAborted: settledAborted,
            assistantFinalText: finalText,
            assistantFinalThinking: finalThinking,
            streamError: streamError,
            retryStatus: retryStatus
        )
    }

    /// Trim noisy provider blobs into something a human can skim.
    static func shortError(_ raw: String) -> String {
        let one = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if one.count <= 120 { return one }
        return String(one.prefix(117)) + "…"
    }

    static func humanize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.contains("connection refused") || lower.contains("econnrefused") {
            return "Can't reach the local model router — is llama.cpp running?"
        }
        if lower.contains("model not found") || lower.contains("no models match") {
            return "Model not available — pick a loaded model in the composer."
        }
        if lower.contains("overloaded") || lower.contains("529") {
            return "Provider overloaded — retrying or try again in a moment."
        }
        if lower.contains("context") && (lower.contains("overflow") || lower.contains("too long") || lower.contains("maximum")) {
            return "Context too long — start a new chat or enable autocompaction."
        }
        if lower.contains("out of memory") || lower.contains("oom") {
            return "Model ran out of memory — try a smaller context or unload other models."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Timed out waiting for the model."
        }
        if lower.contains("unauthorized") || lower.contains("401") || lower.contains("invalid api key") {
            return "Auth failed — check the provider subscription / API key in Settings."
        }
        return shortError(s)
    }
}

extension PiModel {
    static func fromRPC(_ row: [String: Any]) -> PiModel? {
        guard let provider = row["provider"] as? String else { return nil }
        let modelId = (row["id"] as? String) ?? (row["modelId"] as? String)
        guard let modelId else { return nil }
        return PiModel(
            provider: provider,
            modelId: modelId,
            name: row["name"] as? String,
            reasoning: row["reasoning"] as? Bool
        )
    }
}

/// Accumulates stdout bytes and emits complete LF-delimited lines.
actor OutBuffer {
    private var buffer = Data()

    func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
