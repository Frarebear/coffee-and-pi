import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var threads: [ChatThread] = []
    @Published var activeThreadID: UUID?
    @Published var availableModels: [PiModel] = []
    @Published var draft: String = ""
    @Published var bootError: String?
    @Published var detailPane: DetailPane = .chat
    /// `nil` = house lobby shop; otherwise that project's private café.
    @Published var shopProjectID: UUID? = nil
    @Published var expandedProjectIDs: Set<UUID> = []
    @Published var expandedBeanIDs: Set<UUID> = []
    @Published var expandProjects = true
    @Published var expandLooseBeans = true
    @Published var expandLooseChats = true

    let router = RouterManager(modelsMax: 2)
    let auth = AuthStore()
    let projects = ProjectStore()
    let github = GitHubStore()
    let modelProfiles = ModelProfileStore()
    let chatStore = ChatStore()
    let presence = BeanPresenceStore()
    let node = NodeServer()
    let usage = UsageStore()
    let onboarding = OnboardingStore()
    let hardware = HardwareContextFitter.HardwareInfo.current()

    private var clients: [BeanClientKey: PiRPCClient] = [:]
    private var streamingMessageIDs: [BeanClientKey: String] = [:]
    private var persistTask: Task<Void, Never>?
    private var tableTurnTask: Task<Void, Never>?
    private var nestedBags: [AnyCancellable] = []

    init() {
        // Nested ObservableObject — forward so table chrome / shop / devices stay live.
        nestedBags.append(presence.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
        nestedBags.append(node.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
        nestedBags.append(node.pairing.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
        nestedBags.append(usage.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
        nestedBags.append(onboarding.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
        node.attach(app: self)
        usage.load()
        onboarding.onDismiss = { [weak self] in
            Task { @MainActor in
                await self?.finishBootstrapAfterOnboarding()
            }
        }
    }

    /// Router + first client after the first-launch wizard closes (or is skipped).
    func finishBootstrapAfterOnboarding() async {
        await router.ensureRunning()
        syncProfilesFromRouter()
        for profile in modelProfiles.profiles where profile.isAutoCtx && profile.fittedCtxSize == nil {
            let enriched = await enrichWithFittedCtx(profile)
            modelProfiles.upsert(enriched)
        }
        rebuildAvailableModels()
        auth.reload()
        if let id = activeThreadID, activeThread != nil {
            await ensureClient(for: id)
        }
    }

    func refreshUsage() async {
        auth.reload()
        await usage.refreshOpenRouter(apiKey: auth.openRouterAPIKey)
    }

    var activeThread: ChatThread? {
        guard let id = activeThreadID,
              let thread = threads.first(where: { $0.id == id }),
              !thread.isArchived
        else { return nil }
        return thread
    }

    var activeThreadIndex: Int? {
        threads.firstIndex { $0.id == activeThreadID }
    }

    func threads(projectID: UUID?, beanID: UUID?) -> [ChatThread] {
        threads
            .filter { $0.projectID == projectID && $0.beanID == beanID && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// All chats in a project (beans are siblings — chats are not nested under beans).
    func chats(in projectID: UUID) -> [ChatThread] {
        threads
            .filter { $0.projectID == projectID && !$0.isTable && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Chats with no project (may still have a bean association).
    func orphanChats() -> [ChatThread] {
        threads
            .filter { $0.projectID == nil && !$0.isTable && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func archivedChats() -> [ChatThread] {
        threads.filter(\.isArchived).sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
    }

    func preview(for bean: Bean) -> String {
        bean.subtitle
    }

    func chatBeanLabel(_ thread: ChatThread) -> String? {
        if thread.isTable {
            let names = thread.participantBeanIDs.compactMap { projects.bean(id: $0)?.name }
            return names.isEmpty ? "Table" : names.joined(separator: " · ")
        }
        return projects.bean(id: thread.beanID)?.name
    }

    func toggleProjectExpanded(_ id: UUID) {
        if expandedProjectIDs.contains(id) {
            expandedProjectIDs.remove(id)
        } else {
            expandedProjectIDs.insert(id)
        }
    }

    func toggleBeanExpanded(_ id: UUID) {
        if expandedBeanIDs.contains(id) {
            expandedBeanIDs.remove(id)
        } else {
            expandedBeanIDs.insert(id)
        }
    }

    func bootstrap() async {
        projects.load()
        modelProfiles.load()
        threads = chatStore.load()
        sanitizeThreadsAgainstProjects()
        if let id = projects.activeProjectID {
            expandedProjectIDs.insert(id)
        }
        if let id = projects.activeBeanID {
            expandedBeanIDs.insert(id)
        }
        for thread in threads where !thread.isArchived {
            if let pid = thread.projectID { expandedProjectIDs.insert(pid) }
            if let bid = thread.beanID { expandedBeanIDs.insert(bid) }
        }
        if activeThreadID == nil || activeThread == nil {
            activeThreadID = nextVisibleThreadID()
        }
        auth.reload()

        // First-launch wizard only for empty installs. Existing workspaces are never wiped.
        let hasWorkspaceContent = !projects.projects.isEmpty
            || projects.beans.contains(where: { $0.name != "Pi" })
            || !threads.isEmpty
            || !auth.providers.isEmpty
        onboarding.evaluateShouldPresent(hasWorkspaceContent: hasWorkspaceContent)

        // Node API before Pi/router wait — remotes should not block on model boot.
        node.bootstrap()
        await github.refreshAuth()

        // During first-run onboarding, defer router boot until they choose local.
        if !onboarding.isPresented {
            await router.ensureRunning()
            syncProfilesFromRouter()
            for profile in modelProfiles.profiles where profile.isAutoCtx && profile.fittedCtxSize == nil {
                let enriched = await enrichWithFittedCtx(profile)
                modelProfiles.upsert(enriched)
            }
            rebuildAvailableModels()

            // Empty workspace stays empty — don't spawn a chat the user just wiped.
            if let id = activeThreadID, activeThread != nil {
                await ensureClient(for: id)
            }
        } else {
            rebuildAvailableModels()
        }
    }

    /// Chats whose project was removed (e.g. auto-seed strip) become loose so they stay visible/deletable.
    private func sanitizeThreadsAgainstProjects() {
        let live = Set(projects.projects.map(\.id))
        var changed = false
        for i in threads.indices {
            if let pid = threads[i].projectID, !live.contains(pid) {
                threads[i].projectID = nil
                changed = true
            }
        }
        if changed { persistChats() }
    }

    private func nextVisibleThreadID() -> UUID? {
        threads.first(where: { !$0.isArchived })?.id
    }

    func persistChats() {
        chatStore.save(threads)
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            persistChats()
        }
    }

    func syncProfilesFromRouter() {
        let paths = Dictionary(uniqueKeysWithValues: router.routerModels.compactMap { m in
            m.modelPath.map { (m.id, $0) }
        })
        modelProfiles.ensureProfiles(for: router.routerModels.map(\.id), paths: paths)
    }

    /// Download from a pasted Hugging Face URL / `owner/repo[:quant]`.
    func downloadHuggingFaceModel(_ raw: String) async throws -> String {
        let id = try await router.downloadFromHuggingFace(raw)
        syncProfilesFromRouter()
        rebuildAvailableModels()
        return id
    }

    /// Persist + apply per-model knobs (ctx / KV / autocompact / system prompt).
    /// `reload: true` restarts the router so ctx/KV take effect and reloads the model.
    func saveModelProfile(_ profile: LocalModelProfile, reload: Bool = true) async throws {
        var profile = profile
        if profile.isAutoCtx {
            profile = await enrichWithFittedCtx(profile)
        }
        modelProfiles.upsert(profile)
        let isLocal = profile.id.contains("/") || router.routerModels.contains(where: { $0.id == profile.id })
        if isLocal {
            if reload {
                try await router.applyProfile(profile, reloadModel: true)
                // Capture what the router actually loaded.
                if let live = router.routerModels.first(where: { $0.id == profile.id })?.ctxSize, live > 0 {
                    profile.fittedCtxSize = live
                    modelProfiles.upsert(profile)
                }
            } else {
                router.writeProfilePreset(profile)
            }
        }
        syncProfilesFromRouter()
        rebuildAvailableModels()

        // Live-apply autocompaction to chats currently on this model.
        for thread in threads where thread.selectedModel?.provider == "llama.cpp"
            && thread.selectedModel?.modelId == profile.id {
            for key in clients.keys where key.threadID == thread.id {
                if let client = clients[key] {
                    try? await client.setAutoCompaction(profile.autoCompaction)
                }
            }
        }
    }

    var tableThreads: [ChatThread] {
        threads.filter { $0.isTable && !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var shopProject: Project? {
        guard let id = shopProjectID else { return nil }
        return projects.projects.first { $0.id == id }
    }

    var shopTitle: String {
        if let name = shopProject?.name { return name }
        return "House"
    }

    /// Open the house lobby (`projectID == nil`) or a project café.
    func openShop(projectID: UUID? = nil) {
        shopProjectID = projectID
        if let projectID {
            projects.selectProject(projectID)
            expandedProjectIDs.insert(projectID)
        }
        detailPane = .shop
    }

    /// Beans visible in the current shop scope.
    func shopBeans() -> [Bean] {
        if let pid = shopProjectID {
            return projects.beans(in: pid).filter { !$0.isArchived }
        }
        return projects.looseBeans().filter { !$0.isArchived }
    }

    /// Solo chats living in the current shop (not tables).
    func shopChats() -> [ChatThread] {
        if let pid = shopProjectID {
            return chats(in: pid)
        }
        return orphanChats()
    }

    /// Tables for the current shop scope.
    func shopTables() -> [ChatThread] {
        if let pid = shopProjectID {
            return tableThreads.filter { $0.projectID == pid }
        }
        return tableThreads.filter { $0.projectID == nil }
    }

    /// Probe llama-fit-params / heuristic and store estimate on the profile.
    func enrichWithFittedCtx(_ profile: LocalModelProfile) async -> LocalModelProfile {
        var p = profile
        let path = p.modelPath ?? router.routerModels.first(where: { $0.id == p.id })?.modelPath
        let fitted = await HardwareContextFitter.fittedContext(
            modelPath: path,
            hfRepo: path == nil ? p.id : nil,
            cacheTypeK: p.cacheTypeK,
            cacheTypeV: p.cacheTypeV
        )
        if let fitted {
            p.fittedCtxSize = fitted
        } else {
            let bytes: UInt64? = {
                guard let path, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? UInt64 else { return nil }
                return size
            }()
            p.fittedCtxSize = HardwareContextFitter.heuristicContext(modelBytes: bytes, cacheTypeK: p.cacheTypeK)
        }
        return p
    }

    func probeFittedCtx(for profile: LocalModelProfile) async -> Int? {
        let enriched = await enrichWithFittedCtx(profile)
        return enriched.fittedCtxSize
    }

    func rebuildAvailableModels() {
        var map: [String: PiModel] = [:]
        for rm in router.routerModels {
            map["llama.cpp/\(rm.id)"] = PiModel(
                provider: "llama.cpp",
                modelId: rm.id,
                name: rm.id,
                reasoning: true,
                loaded: rm.loaded
            )
        }
        // Keep any previously discovered cloud models
        for m in availableModels where m.provider != "llama.cpp" {
            map[m.id] = m
        }
        availableModels = Array(map.values).sorted { $0.menuLabel < $1.menuLabel }
    }

    /// New chat in the current context (active bean/project), or loose if none.
    func newChat() async {
        await newChat(projectID: projects.activeProjectID, beanID: projects.activeBeanID)
    }

    func newChat(projectID: UUID?, beanID: UUID?) async {
        let bean = projects.bean(id: beanID)
        let project = projectID.flatMap { pid in projects.projects.first { $0.id == pid } }
            ?? bean?.projectID.flatMap { pid in projects.projects.first { $0.id == pid } }

        let preferred: PiModel? = {
            if let bean, let p = bean.defaultProvider, let mid = bean.defaultModelId {
                return availableModels.first { $0.provider == p && $0.modelId == mid }
                    ?? PiModel(provider: p, modelId: mid, name: mid, reasoning: true, loaded: nil)
            }
            return availableModels.first { $0.loaded == true } ?? availableModels.first
        }()

        let model = preferred ?? PiModel(provider: "llama.cpp", modelId: "gemma4-heretic", name: "gemma4-heretic", reasoning: true, loaded: true)
        let resolvedProjectID = project?.id ?? bean?.projectID
        let thread = ChatThread.blank(
            projectID: resolvedProjectID,
            beanID: bean?.id,
            model: model,
            thinking: bean?.defaultThinking ?? .off
        )
        threads.insert(thread, at: 0)
        activeThreadID = thread.id
        detailPane = .chat
        if let pid = resolvedProjectID { expandedProjectIDs.insert(pid) }
        if let bid = bean?.id { expandedBeanIDs.insert(bid) }
        if resolvedProjectID == nil && bean == nil { expandLooseChats = true }
        if bean?.projectID == nil, bean != nil { expandLooseBeans = true }
        projects.selectProject(resolvedProjectID)
        projects.selectBean(bean?.id)
        schedulePersist()

        await startClient(for: thread, project: project, bean: bean, model: model)
    }

    func selectThread(_ id: UUID) {
        activeThreadID = id
        detailPane = .chat
        if let thread = threads.first(where: { $0.id == id }) {
            projects.selectProject(thread.projectID)
            projects.selectBean(thread.beanID)
            if let pid = thread.projectID { expandedProjectIDs.insert(pid) }
            if let bid = thread.beanID { expandedBeanIDs.insert(bid) }
        }
        Task { await ensureClient(for: id) }
    }

    /// Selects a bean as the active agent. Does not nest chats under it —
    /// use "New chat with …" or New chat while this bean is active.
    func selectBean(_ beanID: UUID) {
        guard let bean = projects.bean(id: beanID) else { return }
        projects.selectBean(beanID)
        if let pid = bean.projectID { expandedProjectIDs.insert(pid) }
        detailPane = .chat
        // Prefer an existing chat that used this bean; otherwise just arm it for New chat.
        if let existing = threads
            .filter({
                ($0.beanID == beanID || $0.participantBeanIDs.contains(beanID))
                    && $0.projectID == bean.projectID
                    && !$0.isTable
            })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first {
            activeThreadID = existing.id
            Task { await ensureClient(for: existing.id) }
        }
    }

    /// Grokbot-style create: name → open chat → bean greets from the name alone.
    func onboardNewBean(name: String, projectID: UUID?, selfEdit: Bool = true, accentHue: Double? = nil) async {
        let bean = projects.addBean(
            name: name,
            projectID: projectID,
            selfEdit: selfEdit,
            accentHue: accentHue
        )
        if let projectID { expandedProjectIDs.insert(projectID) }
        if bean.projectID == nil { expandLooseBeans = true }
        expandedBeanIDs.insert(bean.id)
        await newChat(projectID: bean.projectID, beanID: bean.id)
        guard let threadID = activeThreadID else { return }
        await kickstartBeanGreeting(threadID: threadID, beanID: bean.id)
    }

    /// First message is from the bean (no user bubble), inferred from the name.
    private func kickstartBeanGreeting(threadID: UUID, beanID: UUID) async {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard var bean = projects.bean(id: beanID) else { return }
        guard bean.awaitingFirstMessage else { return }

        bean.awaitingFirstMessage = false
        projects.updateBean(bean)

        threads[idx].isBusy = true
        threads[idx].lastError = nil
        threads[idx].updatedAt = Date()
        threads[idx].title = bean.name

        let key = primaryKey(for: threads[idx])
        let assistantID = UUID().uuidString
        threads[idx].messages.append(ChatMessage(
            id: assistantID,
            role: .assistant,
            text: "",
            isStreaming: true,
            streamPhase: .starting,
            speakerBeanID: beanID
        ))
        streamingMessageIDs[key] = assistantID
        schedulePersist()

        await ensureClient(for: threadID)
        guard let freshIdx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let liveKey = primaryKey(for: threads[freshIdx])
        if liveKey != key {
            streamingMessageIDs[liveKey] = assistantID
            streamingMessageIDs[key] = nil
        }
        guard let client = clients[liveKey], await client.isRunning else {
            let detail = threads[freshIdx].lastError ?? bootError ?? "Pi RPC is not running"
            failAssistant(threadID: threadID, assistantID: assistantID, key: liveKey, error: detail)
            return
        }

        let kickstart = """
        [Onboarding — do not mention these brackets] Introduce yourself in one short greeting as \(bean.name). \
        Infer your role entirely from your name. Don't ask for a questionnaire or long brief. \
        Show you already know what you're here for, then ask what to help with first. Stay in character.
        """
        do {
            try await client.prompt(kickstart)
        } catch {
            let stderr = await client.recentStderr
            var detail = error.localizedDescription
            if !stderr.isEmpty {
                let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " | ")
                detail += " — \(tail)"
            }
            failAssistant(threadID: threadID, assistantID: assistantID, key: liveKey, error: detail)
        }
    }

    /// Soft-hide a chat (recoverable from Settings → Archived).
    func archiveThread(_ id: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        stopClients(for: id)
        threads[idx].archivedAt = Date()
        threads[idx].isBusy = false
        if activeThreadID == id {
            activeThreadID = nextVisibleThreadID()
        }
        schedulePersist()
    }

    func unarchiveThread(_ id: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].archivedAt = nil
        schedulePersist()
    }

    /// Permanent delete (also used by older "Close" menu).
    func closeThread(_ id: UUID) {
        deleteThread(id)
    }

    func deleteThread(_ id: UUID) {
        stopClients(for: id)
        presence.clearTable(id)
        threads.removeAll { $0.id == id }
        if activeThreadID == id || activeThread == nil {
            activeThreadID = nextVisibleThreadID()
        }
        schedulePersist()
    }

    /// Wipe every chat (sidebar “deleted everything” should clear the pane too).
    func deleteAllThreads() {
        let ids = threads.map(\.id)
        for id in ids { stopClients(for: id); presence.clearTable(id) }
        threads.removeAll()
        activeThreadID = nil
        schedulePersist()
    }

    private func stopClients(for threadID: UUID) {
        let keys = clients.keys.filter { $0.threadID == threadID }
        for key in keys {
            Task { await clients[key]?.stop() }
            clients[key] = nil
            streamingMessageIDs[key] = nil
        }
    }

    func archiveBean(_ beanID: UUID) {
        projects.archiveBean(beanID)
        // Soft-hide solo chats that belonged only to this bean.
        for i in threads.indices where !threads[i].isArchived {
            if threads[i].beanID == beanID && threads[i].participantBeanIDs.filter({ $0 != beanID }).isEmpty {
                threads[i].archivedAt = Date()
            }
        }
        if activeThreadID.map({ id in threads.first(where: { $0.id == id })?.isArchived == true }) == true {
            activeThreadID = threads.first(where: { !$0.isArchived })?.id
        }
        schedulePersist()
    }

    func unarchiveBean(_ beanID: UUID) {
        projects.unarchiveBean(beanID)
    }

    func deleteBean(_ beanID: UUID) {
        projects.deleteBean(beanID)
        for i in threads.indices {
            if threads[i].beanID == beanID { threads[i].beanID = nil }
            threads[i].participantBeanIDs.removeAll { $0 == beanID }
            if threads[i].isTable && threads[i].participantBeanIDs.count < 2 {
                threads[i].kind = .solo
                threads[i].beanID = threads[i].participantBeanIDs.first
            }
        }
        schedulePersist()
    }

    // MARK: - Table chats (multi-Bean)

    /// Create a shared table with 2+ Beans. Project defaults to first bean's project.
    @discardableResult
    func createTableChat(beanIDs: [UUID], projectID: UUID? = nil) async -> UUID? {
        var unique: [UUID] = []
        for id in beanIDs where !unique.contains(id) { unique.append(id) }
        guard unique.count >= 2 else { return nil }
        let beans = unique.compactMap { projects.bean(id: $0) }
        guard beans.count >= 2 else { return nil }

        let resolvedProject = projectID
            ?? beans.first(where: { $0.projectID != nil })?.projectID
        let host = beans[0]
        let preferred: PiModel? = {
            if let p = host.defaultProvider, let mid = host.defaultModelId {
                return availableModels.first { $0.provider == p && $0.modelId == mid }
                    ?? PiModel(provider: p, modelId: mid, name: mid, reasoning: true, loaded: nil)
            }
            return availableModels.first { $0.loaded == true } ?? availableModels.first
        }()
        let model = preferred ?? PiModel(provider: "llama.cpp", modelId: "gemma4-heretic", name: "gemma4-heretic", reasoning: true, loaded: true)

        var thread = ChatThread.table(
            projectID: resolvedProject,
            beanIDs: unique,
            model: model,
            thinking: host.defaultThinking
        )
        let names = beans.map(\.name).joined(separator: " · ")
        thread.title = "Table · \(names)"

        threads.insert(thread, at: 0)
        activeThreadID = thread.id
        detailPane = .chat
        if let pid = resolvedProject { expandedProjectIDs.insert(pid) }
        for b in unique { expandedBeanIDs.insert(b) }
        presence.setMany(unique, .walking)
        schedulePersist()

        // Seat them after a short walk beat for the shop UI.
        for id in unique {
            presence.set(id, .seated(tableID: thread.id))
        }

        // Warm the host client; others start on their first turn.
        let project = resolvedProject.flatMap { pid in projects.projects.first { $0.id == pid } }
        await startClient(for: thread, project: project, bean: host, model: model)
        return thread.id
    }

    func inviteBean(_ beanID: UUID, to threadID: UUID) async {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard projects.bean(id: beanID) != nil else { return }
        if !threads[idx].isTable {
            threads[idx].kind = .table
            if let existing = threads[idx].beanID, !threads[idx].participantBeanIDs.contains(existing) {
                threads[idx].participantBeanIDs.insert(existing, at: 0)
            }
        }
        guard !threads[idx].participantBeanIDs.contains(beanID) else { return }
        presence.set(beanID, .walking)
        threads[idx].participantBeanIDs.append(beanID)
        if threads[idx].beanID == nil {
            threads[idx].beanID = beanID
        }
        let names = threads[idx].participantBeanIDs.compactMap { projects.bean(id: $0)?.name }
        if threads[idx].title.hasPrefix("Table") || threads[idx].title == "New chat" {
            threads[idx].title = "Table · \(names.joined(separator: " · "))"
        }
        threads[idx].updatedAt = Date()
        presence.set(beanID, .seated(tableID: threadID))
        schedulePersist()
    }

    func removeBean(_ beanID: UUID, from threadID: UUID) async {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[idx].participantBeanIDs.removeAll { $0 == beanID }
        let key = BeanClientKey.seat(threadID: threadID, beanID: beanID)
        if let client = clients[key] {
            await client.stop()
            clients[key] = nil
        }
        streamingMessageIDs[key] = nil
        presence.set(beanID, .idle)
        if threads[idx].beanID == beanID {
            threads[idx].beanID = threads[idx].participantBeanIDs.first
        }
        if threads[idx].participantBeanIDs.count < 2 {
            threads[idx].kind = .solo
        }
        threads[idx].updatedAt = Date()
        schedulePersist()
    }

    /// Run one round of sequential Bean replies at a table.
    /// `onlyBeanIDs` limits the round (e.g. @mentions); nil = all seats.
    func runTableTurn(threadID: UUID, trigger: String? = nil, onlyBeanIDs: [UUID]? = nil) async {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard threads[idx].isTable else { return }
        let seats = threads[idx].participantBeanIDs
        let order: [UUID] = {
            if let only = onlyBeanIDs, !only.isEmpty {
                return seats.filter { only.contains($0) }
            }
            return seats
        }()
        guard !order.isEmpty else { return }

        threads[idx].isBusy = true
        threads[idx].lastError = nil
        schedulePersist()

        let beanMap = Dictionary(uniqueKeysWithValues: projects.beans.map { ($0.id, $0) })
        let project = threads[idx].projectID.flatMap { pid in projects.projects.first { $0.id == pid } }
        let model = threads[idx].selectedModel
            ?? availableModels.first { $0.loaded == true }
            ?? availableModels.first
            ?? PiModel(provider: "llama.cpp", modelId: "gemma4-heretic", name: "gemma4-heretic", reasoning: true, loaded: true)

        if let trigger, !trigger.isEmpty {
            // Already inserted by send(); optional re-prompt text for beans.
            _ = trigger
        }

        for beanID in order {
            guard let bean = beanMap[beanID] else { continue }
            guard let tIdx = threads.firstIndex(where: { $0.id == threadID }) else { return }

            presence.set(beanID, .speaking(tableID: threadID))
            let transcript = TableTurnCoordinator.transcriptSnippet(
                messages: threads[tIdx].messages,
                beans: beanMap
            )
            var handoff = ""
            for linkedID in threads[tIdx].linkedThreadIDs {
                if let linked = threads.first(where: { $0.id == linkedID }) {
                    handoff += TableTurnCoordinator.handoffBlock(from: linked, beans: beanMap)
                }
            }
            let rules = TableTurnCoordinator.tableSystemRules(
                bean: bean,
                seats: seats.compactMap { beanMap[$0] },
                transcript: transcript + handoff
            )

            let key = BeanClientKey.seat(threadID: threadID, beanID: beanID)
            await ensureClient(for: threads[tIdx], bean: bean, model: model, project: project, extraSystem: rules)

            let assistantID = UUID().uuidString
            let assistantMsg = ChatMessage(
                id: assistantID,
                role: .assistant,
                text: "",
                isStreaming: true,
                streamPhase: .starting,
                speakerBeanID: beanID
            )
            threads[tIdx].messages.append(assistantMsg)
            streamingMessageIDs[key] = assistantID
            schedulePersist()

            let prompt = trigger?.isEmpty == false
                ? "The human said: \(trigger!)\nRespond as \(bean.name) at the table."
                : "Continue the table conversation as \(bean.name). Respond to the latest messages."

            do {
                guard let client = clients[key], await client.isRunning else {
                    failAssistant(threadID: threadID, assistantID: assistantID, key: key, error: "Pi RPC is not running")
                    continue
                }
                try await client.prompt(prompt)
                // Wait until settled (handler clears streaming flag).
                for _ in 0..<600 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if streamingMessageIDs[key] == nil { break }
                    if Task.isCancelled { break }
                }
            } catch {
                let stderr = await clients[key]?.recentStderr ?? ""
                var detail = error.localizedDescription
                if !stderr.isEmpty {
                    let tail = stderr.split(separator: "\n").suffix(2).joined(separator: " | ")
                    detail += " — \(tail)"
                }
                failAssistant(threadID: threadID, assistantID: assistantID, key: key, error: detail)
            }

            presence.set(beanID, .seated(tableID: threadID))
        }

        if let i = threads.firstIndex(where: { $0.id == threadID }) {
            threads[i].isBusy = false
            threads[i].updatedAt = Date()
        }
        schedulePersist()
    }

    // MARK: - Transcript handoff

    /// Attach another chat's transcript so the active Bean can work with it.
    func workWith(threadID sourceID: UUID, into targetID: UUID) async {
        guard sourceID != targetID,
              let source = threads.first(where: { $0.id == sourceID }),
              let idx = threads.firstIndex(where: { $0.id == targetID })
        else { return }

        if !threads[idx].linkedThreadIDs.contains(sourceID) {
            threads[idx].linkedThreadIDs.append(sourceID)
        }

        if let beanID = threads[idx].beanID ?? threads[idx].participantBeanIDs.first {
            presence.set(beanID, .handoff(fromThreadID: sourceID))
        }

        let beanMap = Dictionary(uniqueKeysWithValues: projects.beans.map { ($0.id, $0) })
        let block = TableTurnCoordinator.handoffBlock(from: source, beans: beanMap)
        let note = ChatMessage(
            id: UUID().uuidString,
            role: .system,
            text: "Linked chat \"\(source.title)\" for handoff.\n\(block)",
            speakerBeanID: nil
        )
        threads[idx].messages.append(note)
        threads[idx].updatedAt = Date()
        schedulePersist()

        // Restart primary client so append-system includes handoff on next prompt path.
        let target = threads[idx]
        let project = target.projectID.flatMap { pid in projects.projects.first { $0.id == pid } }
        let bean = projects.bean(id: target.beanID ?? target.participantBeanIDs.first)
        let model = target.selectedModel
            ?? availableModels.first
            ?? PiModel(provider: "llama.cpp", modelId: "gemma4-heretic", name: "gemma4-heretic", reasoning: true, loaded: true)
        await startClient(for: target, project: project, bean: bean, model: model, extraSystem: block)

        if let beanID = bean?.id {
            presence.set(beanID, target.isTable ? .seated(tableID: targetID) : .idle)
        }
    }

    /// Attach an external transcript (Cursor agent JSONL, etc.) into a chat as handoff context.
    func workWithTranscriptFile(at url: URL, into targetID: UUID) async {
        guard let idx = threads.firstIndex(where: { $0.id == targetID }) else { return }
        guard let data = try? Data(contentsOf: url) else {
            threads[idx].lastError = "Could not read \(url.lastPathComponent)"
            return
        }
        let summary = TableTurnCoordinator.summarizeJSONL(data)
        let block = TableTurnCoordinator.handoffBlock(fromExternal: url.lastPathComponent, body: summary)

        if let beanID = threads[idx].beanID ?? threads[idx].participantBeanIDs.first {
            presence.set(beanID, .handoff(fromThreadID: targetID))
        }

        let note = ChatMessage(
            id: UUID().uuidString,
            role: .system,
            text: "Linked external transcript \"\(url.lastPathComponent)\" for handoff.\n\(block)",
            speakerBeanID: nil
        )
        threads[idx].messages.append(note)
        threads[idx].updatedAt = Date()
        schedulePersist()

        let target = threads[idx]
        let project = target.projectID.flatMap { pid in projects.projects.first { $0.id == pid } }
        let bean = projects.bean(id: target.beanID ?? target.participantBeanIDs.first)
        let model = target.selectedModel
            ?? availableModels.first
            ?? PiModel(provider: "llama.cpp", modelId: "gemma4-heretic", name: "gemma4-heretic", reasoning: true, loaded: true)
        await startClient(for: target, project: project, bean: bean, model: model, extraSystem: block)

        if let beanID = bean?.id {
            presence.set(beanID, target.isTable ? .seated(tableID: targetID) : .idle)
        }
    }

    /// Ensure Local + Codex + Cursor Beans exist for the multi-provider shop demo.
    @discardableResult
    func seatTheHouse(projectID: UUID? = nil) -> [UUID] {
        let pid = projectID ?? projects.activeProjectID
        var ids: [UUID] = []

        func ensure(
            name: String,
            provider: String?,
            modelId: String?,
            instructions: String,
            hue: Double,
            selfEdit: Bool
        ) -> UUID {
            if let existing = projects.beans.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    && ($0.projectID == pid || (pid == nil && $0.projectID == nil))
            }) {
                var updated = existing
                if updated.defaultProvider == nil { updated.defaultProvider = provider }
                if updated.defaultModelId == nil { updated.defaultModelId = modelId }
                projects.updateBean(updated)
                return existing.id
            }
            let bean = Bean(
                name: name,
                instructions: instructions,
                projectID: pid,
                defaultProvider: provider,
                defaultModelId: modelId,
                defaultThinking: .off,
                allowsSelfEdit: selfEdit,
                accentHue: hue
            )
            projects.insertBean(bean)
            return bean.id
        }

        let localModel = availableModels.first { $0.provider == "llama.cpp" && $0.loaded == true }
            ?? availableModels.first { $0.provider == "llama.cpp" }
        ids.append(ensure(
            name: "Local",
            provider: "llama.cpp",
            modelId: localModel?.modelId ?? "gemma4-heretic",
            instructions: "You are Local, a Coffee & Pi bean on llama.cpp. Be direct and ship working changes.",
            hue: 0.08,
            selfEdit: true
        ))

        let codex = availableModels.first {
            let p = $0.provider.lowercased()
            let m = $0.modelId.lowercased()
            return p.contains("openai") || p.contains("codex") || m.contains("codex") || m.contains("gpt")
        }
        ids.append(ensure(
            name: "Codex",
            provider: codex?.provider ?? "openai",
            modelId: codex?.modelId ?? "codex",
            instructions: "You are Codex at the Coffee & Pi table. Collaborate with Local and Cursor beans; be concrete.",
            hue: 0.45,
            selfEdit: false
        ))

        ids.append(ensure(
            name: "Cursor",
            provider: "cursor",
            modelId: nil,
            instructions: """
            You are Cursor, a handoff-oriented bean. You don't run a native Cursor RPC here — \
            work from attached Cursor agent transcripts (Work with → Open transcript…) and \
            help Local / Codex act on that context. Be concise and actionable.
            """,
            hue: 0.62,
            selfEdit: false
        ))

        if let first = ids.first {
            projects.selectBean(first)
        }
        return ids
    }

    func setModel(_ model: PiModel) async {
        guard let idx = activeThreadIndex else { return }
        let thread = threads[idx]
        let key = primaryKey(for: thread)

        do {
            if model.provider == "llama.cpp" {
                // Ensure this model's preset knobs (incl. Auto fit) are on disk before load.
                var profile = modelProfiles.profile(for: model.modelId)
                if profile.isAutoCtx {
                    profile = await enrichWithFittedCtx(profile)
                    router.writeProfilePreset(profile)
                }
                modelProfiles.upsert(profile)
                try await router.loadModel(model.modelId)
                if let live = router.routerModels.first(where: { $0.id == model.modelId })?.ctxSize, live > 0 {
                    profile.fittedCtxSize = live
                    modelProfiles.upsert(profile)
                }
                rebuildAvailableModels()
            }

            if let client = clients[key] {
                do {
                    try await client.setModel(provider: model.provider, modelId: model.modelId)
                    if model.provider == "llama.cpp" {
                        let profile = modelProfiles.profile(for: model.modelId)
                        try? await client.setAutoCompaction(profile.autoCompaction)
                    }
                } catch {
                    // Pi may not know the model until models.json sync + restart
                    await client.stop()
                    clients[key] = nil
                    var t = threads[idx]
                    t.selectedModel = model
                    threads[idx] = t
                    let project = t.projectID.flatMap { pid in projects.projects.first { $0.id == pid } }
                    let bean = projects.bean(id: t.beanID)
                    await startClient(for: t, project: project, bean: bean, model: model)
                }
            }

            threads[idx].selectedModel = model
            threads[idx].lastError = nil
            schedulePersist()
            rebuildAvailableModels()
        } catch {
            threads[idx].lastError = error.localizedDescription
        }
    }

    func setThinking(_ level: ThinkingLevel) async {
        guard let idx = activeThreadIndex else { return }
        let key = primaryKey(for: threads[idx])
        guard let client = clients[key] else { return }
        do {
            try await client.setThinkingLevel(level)
            threads[idx].thinkingLevel = level
            threads[idx].lastError = nil
            schedulePersist()
        } catch {
            threads[idx].lastError = error.localizedDescription
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let idx = activeThreadIndex else { return }
        draft = ""
        await sendMessage(threadID: threads[idx].id, text: text)
    }

    enum RemoteSendError: LocalizedError {
        case chatNotFound
        case emptyText

        var errorDescription: String? {
            switch self {
            case .chatNotFound: return "Chat not found"
            case .emptyText: return "Message text required"
            }
        }
    }

    /// Remote / API entry: send into a specific chat (does not touch composer draft).
    /// Runs entirely on this Mac (Pi + models). Callers should not run inference on the phone.
    func sendRemoteMessage(chatID: UUID, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemoteSendError.emptyText }
        guard threads.contains(where: { $0.id == chatID }) else { throw RemoteSendError.chatNotFound }
        activeThreadID = chatID
        detailPane = .chat
        await sendMessage(threadID: chatID, text: trimmed)
    }

    /// Thin-client enqueue: park the user message on this node and start Pi in the background.
    @discardableResult
    func enqueueRemoteMessage(chatID: UUID, text: String) throws -> ChatThread {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemoteSendError.emptyText }
        guard let idx = threads.firstIndex(where: { $0.id == chatID }) else {
            throw RemoteSendError.chatNotFound
        }
        activeThreadID = chatID
        detailPane = .chat
        Task { await sendMessage(threadID: chatID, text: trimmed) }
        // sendMessage appends async; mirror a pending state so 202 has something useful.
        threads[idx].isBusy = true
        threads[idx].lastError = nil
        threads[idx].updatedAt = Date()
        schedulePersist()
        return threads[idx]
    }

    private func sendMessage(threadID: UUID, text: String) async {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let isTable = threads[idx].isTable

        let userMsg = ChatMessage(id: UUID().uuidString, role: .user, text: text, speakerBeanID: nil)
        threads[idx].messages.append(userMsg)
        threads[idx].isBusy = true
        threads[idx].lastError = nil
        threads[idx].updatedAt = Date()
        if !threads[idx].isTable, threads[idx].title == "New chat" {
            threads[idx].title = String(text.prefix(42))
        }
        schedulePersist()

        // @mentions → invite missing beans to the table, then turn.
        let mentioned = TableTurnCoordinator.mentionedBeanIDs(in: text, beans: projects.beans)
        if !mentioned.isEmpty {
            if !threads[idx].isTable, let host = threads[idx].beanID {
                // Promote solo → table when inviting others.
                let seats = [host] + mentioned.filter { $0 != host }
                if seats.count >= 2 {
                    threads[idx].kind = .table
                    threads[idx].participantBeanIDs = seats
                    for bid in mentioned where bid != host {
                        await inviteBean(bid, to: threadID)
                    }
                }
            } else if threads[idx].isTable {
                for bid in mentioned where !threads[idx].participantBeanIDs.contains(bid) {
                    await inviteBean(bid, to: threadID)
                }
            }
        }

        if isTable || threads[idx].isTable {
            let only = mentioned.isEmpty ? nil : mentioned
            await runTableTurn(threadID: threadID, trigger: text, onlyBeanIDs: only)
            return
        }

        // Show a live bubble immediately — before Pi boot — so the chat never looks dead.
        let key = primaryKey(for: threads[idx])
        let assistantID = UUID().uuidString
        let speaker = threads[idx].beanID
        threads[idx].messages.append(ChatMessage(
            id: assistantID,
            role: .assistant,
            text: "",
            isStreaming: true,
            streamPhase: .starting,
            speakerBeanID: speaker
        ))
        streamingMessageIDs[key] = assistantID
        schedulePersist()

        await ensureClient(for: threadID)
        guard let freshIdx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let liveKey = primaryKey(for: threads[freshIdx])
        // Keep streaming id keyed to the live client (same key unless bean changed).
        if liveKey != key {
            streamingMessageIDs[liveKey] = assistantID
            streamingMessageIDs[key] = nil
        }
        guard let client = clients[liveKey], await client.isRunning else {
            let detail = threads[freshIdx].lastError ?? bootError ?? "Pi RPC is not running"
            failAssistant(threadID: threadID, assistantID: assistantID, key: liveKey, error: detail)
            return
        }

        do {
            try await client.prompt(text)
        } catch {
            let stderr = await client.recentStderr
            var detail = error.localizedDescription
            if !stderr.isEmpty {
                let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " | ")
                detail += " — \(tail)"
            }
            failAssistant(threadID: threadID, assistantID: assistantID, key: liveKey, error: detail)
        }
    }

    private func failAssistant(threadID: UUID, assistantID: String, key: BeanClientKey, error: String) {
        guard let i = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let clean = RPCEvent.humanize(error)
        threads[i].lastError = clean
        threads[i].isBusy = false
        if let m = threads[i].messages.firstIndex(where: { $0.id == assistantID }) {
            applyFailure(to: &threads[i].messages[m], text: clean)
        }
        streamingMessageIDs[key] = nil
        schedulePersist()
    }

    private func applyFailure(to message: inout ChatMessage, text: String) {
        message.isStreaming = false
        message.streamPhase = .idle
        message.activeToolName = nil
        message.isError = true
        if message.text.isEmpty || message.text.hasPrefix("Error:") {
            message.text = text
        } else if !message.text.contains(text) {
            message.text += "\n\n⚠ \(text)"
        }
    }

    /// Kick another round without a new user message (“Talk among yourselves”).
    func beansKeepTalking() async {
        guard let id = activeThreadID, let thread = threads.first(where: { $0.id == id }), thread.isTable else { return }
        await runTableTurn(threadID: id, trigger: nil, onlyBeanIDs: nil)
    }

    func abort() async {
        guard let id = activeThreadID else { return }
        await abortRemote(chatID: id)
    }

    /// Abort a specific chat (local composer or remote node API).
    func abortRemote(chatID id: UUID) async {
        tableTurnTask?.cancel()
        let keys = clients.keys.filter { $0.threadID == id }
        for key in keys {
            try? await clients[key]?.abort()
            if let mid = streamingMessageIDs[key],
               let idx = threads.firstIndex(where: { $0.id == id }),
               let m = threads[idx].messages.firstIndex(where: { $0.id == mid }) {
                threads[idx].messages[m].isStreaming = false
                threads[idx].messages[m].streamPhase = .idle
                threads[idx].messages[m].activeToolName = nil
            }
            streamingMessageIDs[key] = nil
        }
        if let idx = threads.firstIndex(where: { $0.id == id }) {
            threads[idx].isBusy = false
        }
        node.notifyChatChanged(id, force: true)
    }

    func refreshModelsFromPi() async {
        guard let thread = activeThread else {
            rebuildAvailableModels()
            return
        }
        let key = primaryKey(for: thread)
        guard let client = clients[key] else {
            rebuildAvailableModels()
            return
        }
        if let models = try? await client.getAvailableModels() {
            for m in models where m.provider != "llama.cpp" {
                if !availableModels.contains(where: { $0.id == m.id }) {
                    availableModels.append(m)
                }
            }
        }
        rebuildAvailableModels()
    }

    // MARK: - Pi process

    private func primaryKey(for thread: ChatThread) -> BeanClientKey {
        BeanClientKey.solo(threadID: thread.id, beanID: thread.beanID ?? thread.participantBeanIDs.first)
    }

    private func ensureClient(for threadID: UUID) async {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return }
        let project = thread.projectID.flatMap { pid in projects.projects.first { $0.id == pid } }
        let bean = projects.bean(id: thread.beanID ?? thread.participantBeanIDs.first)
        let model = thread.selectedModel
            ?? availableModels.first { $0.loaded == true }
            ?? availableModels.first
            ?? PiModel(provider: "llama.cpp", modelId: "gemma4-heretic", name: "gemma4-heretic", reasoning: true, loaded: true)
        await ensureClient(for: thread, bean: bean, model: model, project: project, extraSystem: nil)
    }

    private func ensureClient(
        for thread: ChatThread,
        bean: Bean?,
        model: PiModel,
        project: Project?,
        extraSystem: String?
    ) async {
        let key = BeanClientKey(threadID: thread.id, beanID: bean?.id ?? thread.beanID)
        if let existing = clients[key], await existing.isRunning {
            return
        }
        await startClient(for: thread, project: project, bean: bean, model: model, extraSystem: extraSystem)
    }

    private func startClient(
        for thread: ChatThread,
        project: Project?,
        bean: Bean?,
        model: PiModel,
        extraSystem: String? = nil
    ) async {
        let key = BeanClientKey(threadID: thread.id, beanID: bean?.id ?? thread.beanID)
        if let old = clients[key] {
            await old.stop()
        }
        let client = PiRPCClient()
        clients[key] = client
        let threadID = thread.id
        let beanID = key.beanID
        await client.setEventHandler { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event, key: BeanClientKey(threadID: threadID, beanID: beanID))
            }
        }
        await client.setExitHandler { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                let key = BeanClientKey(threadID: threadID, beanID: beanID)
                let msg = code == 0
                    ? "Pi stopped unexpectedly."
                    : "Pi crashed (exit \(code))."
                self.bootError = msg
                if let mid = self.streamingMessageIDs[key] {
                    self.failAssistant(threadID: threadID, assistantID: mid, key: key, error: msg)
                } else if let idx = self.threads.firstIndex(where: { $0.id == threadID }) {
                    self.threads[idx].lastError = msg
                    if !self.threads[idx].isTable { self.threads[idx].isBusy = false }
                    self.schedulePersist()
                }
                if let existing = self.clients[key], await existing.isRunning == false {
                    self.clients[key] = nil
                }
            }
        }

        let cwd = project?.path ?? NSHomeDirectory()
        var append = bean?.instructions ?? "You are Pi in Coffee & Pi. Be direct and useful."
        if model.provider == "llama.cpp" {
            let profilePrompt = modelProfiles.profile(for: model.modelId).systemPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !profilePrompt.isEmpty {
                append += "\n\n" + profilePrompt
            }
        }
        if let extraSystem, !extraSystem.isEmpty {
            append += "\n\n" + extraSystem
        }
        // Linked handoffs for solo chats.
        if !thread.linkedThreadIDs.isEmpty {
            let beanMap = Dictionary(uniqueKeysWithValues: projects.beans.map { ($0.id, $0) })
            for linkedID in thread.linkedThreadIDs {
                if let linked = threads.first(where: { $0.id == linkedID }) {
                    append += TableTurnCoordinator.handoffBlock(from: linked, beans: beanMap)
                }
            }
        }
        if bean?.allowsSelfEdit == true, let project {
            append += """


Self-edit rules for this project:
- Working directory is \(project.path)
- You may edit any file in this project, including the Coffee & Pi SwiftUI app under Sources/
- After UI/code changes, rebuild+relaunch with: Scripts/rebuild-and-relaunch.sh
- Prefer small, working diffs. Don't ask permission for edits in this repo.
"""
        }

        let sessionDir = chatStore.sessionsDirectory.path
        let sessionID = "\(thread.piSessionID)-\(key.sessionSuffix)"
        do {
            try await client.start(
                cwd: cwd,
                provider: model.provider,
                model: model.modelId,
                thinking: thread.thinkingLevel,
                appendSystemPrompt: append,
                sessionDir: sessionDir,
                sessionID: sessionID
            )
            if model.provider == "llama.cpp" {
                let profile = modelProfiles.profile(for: model.modelId)
                try? await client.setAutoCompaction(profile.autoCompaction)
            }
            // Only hydrate solo host sessions into the shared thread UI.
            if !thread.isTable, beanID == thread.beanID,
               let piMessages = try? await client.getMessages(), !piMessages.isEmpty,
               let idx = threads.firstIndex(where: { $0.id == threadID }) {
                let visible = piMessages.filter { msg in
                    guard msg.role == .user || msg.role == .assistant else { return false }
                    // Hide Grokbot-style onboarding kickstart (bean greets first; no user bubble).
                    if msg.role == .user, msg.text.hasPrefix("[Onboarding") { return false }
                    return true
                }
                let localEmpty = threads[idx].messages.isEmpty
                let localShorter = threads[idx].messages.count < visible.count
                if (localEmpty || localShorter), !visible.isEmpty {
                    threads[idx].messages = visible.map { msg in
                        var m = msg
                        if m.role == .assistant { m.speakerBeanID = beanID }
                        return m
                    }
                    if threads[idx].title == "New chat",
                       let firstUser = visible.first(where: { $0.role == .user }) {
                        threads[idx].title = String(firstUser.text.prefix(42))
                    }
                    schedulePersist()
                }
            }
            await refreshModelsFromPi()
            if let idx = threads.firstIndex(where: { $0.id == threadID }) {
                threads[idx].lastError = nil
            }
        } catch {
            let stderr = await client.recentStderr
            var detail = error.localizedDescription
            if !stderr.isEmpty {
                let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " | ")
                detail += " — \(tail)"
            }
            if let idx = threads.firstIndex(where: { $0.id == threadID }) {
                threads[idx].lastError = detail
                schedulePersist()
            }
            bootError = detail
            clients[key] = nil
            await client.stop()
        }
    }

    private func handle(event: RPCEvent, key: BeanClientKey) {
        let threadID = key.threadID
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }

        let hasStreamPayload = event.textDelta != nil
            || event.thinkingDelta != nil
            || event.phase != nil
            || event.streamError != nil
            || event.retryStatus != nil
            || event.assistantFinalText != nil
            || event.assistantFinalThinking != nil
            || event.isSettled

        if hasStreamPayload {
            ensureStreamingMessage(for: key, in: idx)
        }

        if let mid = streamingMessageIDs[key],
           let m = threads[idx].messages.firstIndex(where: { $0.id == mid }) {
            if let phase = event.phase {
                threads[idx].messages[m].streamPhase = phase
                threads[idx].isBusy = true
            }
            if let retry = event.retryStatus, !retry.isEmpty {
                threads[idx].messages[m].streamPhase = .retrying
                threads[idx].messages[m].activeToolName = retry
                threads[idx].isBusy = true
                // Show retry reason in the banner without failing the turn yet.
                threads[idx].lastError = retry
            }
            if let tool = event.toolName {
                threads[idx].messages[m].activeToolName = tool
                threads[idx].messages[m].streamPhase = .tooling
            }
            if let thinking = event.thinkingDelta, !thinking.isEmpty {
                threads[idx].messages[m].thinkingText += thinking
                if threads[idx].messages[m].streamPhase != .responding {
                    threads[idx].messages[m].streamPhase = .thinking
                }
            }
            if let delta = event.textDelta, !delta.isEmpty {
                // Successful tokens — clear prior transient retry banner.
                if threads[idx].messages[m].streamPhase == .retrying || threads[idx].lastError?.hasPrefix("Retrying") == true {
                    threads[idx].lastError = nil
                }
                threads[idx].messages[m].isError = false
                threads[idx].messages[m].text += delta
                threads[idx].messages[m].streamPhase = .responding
                threads[idx].messages[m].activeToolName = nil
            }
            // Push live state to paired phones over the node WebSocket.
            node.notifyChatChanged(threadID)
            if let err = event.streamError, !err.isEmpty {
                applyFailure(to: &threads[idx].messages[m], text: err)
                threads[idx].lastError = err
            }
            threads[idx].updatedAt = Date()
        }

        if let finalText = event.assistantFinalText, !finalText.isEmpty {
            if let mid = streamingMessageIDs[key],
               let m = threads[idx].messages.firstIndex(where: { $0.id == mid }) {
                if threads[idx].messages[m].text.isEmpty || !threads[idx].messages[m].isError {
                    // Don't clobber an error notice with empty/partial success text unless empty.
                    if threads[idx].messages[m].text.isEmpty {
                        threads[idx].messages[m].text = finalText
                        threads[idx].messages[m].isError = false
                    } else if !threads[idx].messages[m].isError {
                        // Prefer streamed text; only fill if somehow empty above.
                    }
                }
            }
            threads[idx].updatedAt = Date()
        }
        if let finalThinking = event.assistantFinalThinking, !finalThinking.isEmpty {
            if let mid = streamingMessageIDs[key],
               let m = threads[idx].messages.firstIndex(where: { $0.id == mid }) {
                if threads[idx].messages[m].thinkingText.isEmpty {
                    threads[idx].messages[m].thinkingText = finalThinking
                }
            }
        }

        if event.isSettled {
            if let mid = streamingMessageIDs[key],
               let m = threads[idx].messages.firstIndex(where: { $0.id == mid }) {
                let empty = threads[idx].messages[m].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if event.settledAborted, empty, !threads[idx].messages[m].isError {
                    applyFailure(to: &threads[idx].messages[m], text: "Stopped before a reply came back.")
                    threads[idx].lastError = threads[idx].messages[m].text
                } else if empty, !threads[idx].messages[m].isError {
                    applyFailure(
                        to: &threads[idx].messages[m],
                        text: threads[idx].lastError ?? "No reply from the model."
                    )
                    threads[idx].lastError = threads[idx].messages[m].text
                } else {
                    threads[idx].messages[m].isStreaming = false
                    threads[idx].messages[m].streamPhase = .idle
                    threads[idx].messages[m].activeToolName = nil
                    if !threads[idx].messages[m].isError {
                        // Successful turn — drop transient banners (retry status etc.).
                        if threads[idx].lastError?.hasPrefix("Retrying") == true {
                            threads[idx].lastError = nil
                        }
                        let provider = threads[idx].selectedModel?.provider
                            ?? projects.bean(id: key.beanID)?.defaultProvider
                            ?? "llama.cpp"
                        let assistantText = threads[idx].messages[m].text
                        let userChars = threads[idx].messages.last(where: { $0.role == .user })?.text.count ?? 0
                        usage.recordTurn(
                            provider: provider,
                            userChars: userChars,
                            assistantChars: assistantText.count
                        )
                    }
                }
            }
            streamingMessageIDs[key] = nil
            // Table turns manage isBusy across the whole round.
            if !threads[idx].isTable {
                threads[idx].isBusy = false
            }
            schedulePersist()
            node.notifyChatChanged(threadID, force: true)
        }
    }

    private func ensureStreamingMessage(for key: BeanClientKey, in idx: Int) {
        if let mid = streamingMessageIDs[key],
           threads[idx].messages.contains(where: { $0.id == mid }) {
            return
        }
        let newID = UUID().uuidString
        streamingMessageIDs[key] = newID
        threads[idx].messages.append(ChatMessage(
            id: newID,
            role: .assistant,
            text: "",
            isStreaming: true,
            streamPhase: .starting,
            speakerBeanID: key.beanID
        ))
        threads[idx].isBusy = true
    }
}
