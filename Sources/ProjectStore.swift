import Foundation

/// Persists projects + beans. Beans may belong to a project or float free.
@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var beans: [Bean] = []
    @Published var activeProjectID: UUID?
    @Published var activeBeanID: UUID?

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CoffeeAndPi", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("workspace.json")
    }

    /// Legacy path from before workspace.json.
    private var legacyProjectsURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("projects.json")
    }

    var activeProject: Project? {
        guard let id = activeProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    var activeBean: Bean? {
        if let id = activeBeanID, let bean = beans.first(where: { $0.id == id }) {
            return bean
        }
        return nil
    }

    func beans(in projectID: UUID) -> [Bean] {
        beans.filter { $0.projectID == projectID && !$0.isArchived }
    }

    func looseBeans() -> [Bean] {
        beans.filter { $0.projectID == nil && !$0.isArchived }
    }

    func archivedBeans() -> [Bean] {
        beans.filter(\.isArchived).sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
    }

    func bean(id: UUID?) -> Bean? {
        guard let id else { return nil }
        return beans.first { $0.id == id }
    }

    func load() {
        if loadWorkspace() { return }
        if migrateLegacyProjects() { return }

        // Fresh install: empty workspace — user adds beans/projects themselves.
        projects = []
        beans = []
        activeProjectID = nil
        activeBeanID = nil
        save()
    }

    private func loadWorkspace() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(WorkspaceFile.self, from: data)
        else { return false }
        // Empty file after user wiped beans/projects is still a valid workspace.
        projects = decoded.projects
        beans = decoded.beans
        activeProjectID = decoded.activeProjectID
        activeBeanID = decoded.activeBeanID ?? beans.first?.id
        stripAutoSeededAppProject()
        if activeBeanID == nil { activeBeanID = beans.first?.id }
        return true
    }

    private func migrateLegacyProjects() -> Bool {
        guard let data = try? Data(contentsOf: legacyProjectsURL),
              let legacy = try? JSONDecoder().decode([LegacyProject].self, from: data),
              !legacy.isEmpty
        else { return false }

        var nextProjects: [Project] = []
        var nextBeans: [Bean] = []
        for lp in legacy {
            nextProjects.append(Project(
                id: lp.id,
                name: lp.name,
                path: lp.path,
                githubRemote: lp.githubRemote ?? ""
            ))
            for bot in lp.bots ?? [] {
                nextBeans.append(Bean(
                    id: bot.id,
                    name: bot.name,
                    instructions: bot.instructions,
                    projectID: lp.id,
                    defaultProvider: bot.defaultProvider,
                    defaultModelId: bot.defaultModelId,
                    defaultThinking: bot.defaultThinking ?? .off,
                    allowsSelfEdit: bot.allowsSelfEdit ?? true,
                    accentHue: bot.accentHue ?? 0.08
                ))
            }
        }
        projects = nextProjects
        beans = nextBeans
        activeProjectID = projects.first?.id
        activeBeanID = beans.first?.id
        stripAutoSeededAppProject()
        if activeBeanID == nil { activeBeanID = beans.first?.id }
        save()
        return true
    }

    /// Drop the old forced self-edit project (`~/Developer/coffee-and-pi`).
    /// Beans that lived there become loose; add that folder again via New project if you want it.
    private func stripAutoSeededAppProject() {
        let doomed = projects.filter { project in
            (project.path.hasSuffix("/coffee-and-pi") || project.path.hasSuffix("/Developer/coffee-and-pi"))
                && (project.name == "Coffee & Pi" || project.name == "coffee-and-pi")
        }
        guard !doomed.isEmpty else { return }
        let doomedIDs = Set(doomed.map(\.id))
        for i in beans.indices where beans[i].projectID.map(doomedIDs.contains) == true {
            beans[i].projectID = nil
        }
        projects.removeAll { doomedIDs.contains($0.id) }
        if activeProjectID.map(doomedIDs.contains) == true {
            activeProjectID = nil
        }
        save()
    }

    func save() {
        let payload = WorkspaceFile(
            projects: projects,
            beans: beans,
            activeProjectID: activeProjectID,
            activeBeanID: activeBeanID
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func selectProject(_ id: UUID?) {
        activeProjectID = id
        if let id {
            activeBeanID = beans(in: id).first?.id ?? activeBeanID
        }
        save()
    }

    func selectBean(_ id: UUID?) {
        activeBeanID = id
        if let bean = bean(id: id) {
            activeProjectID = bean.projectID
        }
        save()
    }

    func clearProjectSelection() {
        activeProjectID = nil
        save()
    }

    func addProject(name: String, path: String, githubRemote: String = "") {
        let project = Project(id: UUID(), name: name, path: path, githubRemote: githubRemote)
        let bean = Bean.makeDefaultPi(projectID: project.id)
        projects.append(project)
        beans.append(bean)
        activeProjectID = project.id
        activeBeanID = bean.id
        save()
    }

    func updateProject(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        save()
    }

    func addBean(name: String, projectID: UUID?, selfEdit: Bool, accentHue: Double? = nil) -> Bean {
        let bean = Bean.make(name: name, projectID: projectID, selfEdit: selfEdit, accentHue: accentHue)
        beans.append(bean)
        activeBeanID = bean.id
        activeProjectID = projectID
        save()
        return bean
    }

    /// Insert a fully-specified Bean (shop seeding, etc.).
    func insertBean(_ bean: Bean) {
        if let idx = beans.firstIndex(where: { $0.id == bean.id }) {
            beans[idx] = bean
        } else {
            beans.append(bean)
        }
        activeBeanID = bean.id
        activeProjectID = bean.projectID
        save()
    }

    func updateBean(_ bean: Bean) {
        guard let idx = beans.firstIndex(where: { $0.id == bean.id }) else { return }
        beans[idx] = bean
        save()
    }

    func moveBean(_ beanID: UUID, toProject projectID: UUID?) {
        guard let idx = beans.firstIndex(where: { $0.id == beanID }) else { return }
        beans[idx].projectID = projectID
        activeBeanID = beanID
        activeProjectID = projectID
        save()
    }

    func archiveBean(_ beanID: UUID) {
        guard let idx = beans.firstIndex(where: { $0.id == beanID }) else { return }
        beans[idx].archivedAt = Date()
        if activeBeanID == beanID {
            activeBeanID = beans.first(where: { !$0.isArchived })?.id
        }
        save()
    }

    func unarchiveBean(_ beanID: UUID) {
        guard let idx = beans.firstIndex(where: { $0.id == beanID }) else { return }
        beans[idx].archivedAt = nil
        save()
    }

    /// Permanent remove. Caller should detach chats from this bean.
    func deleteBean(_ beanID: UUID) {
        beans.removeAll { $0.id == beanID }
        if activeBeanID == beanID {
            activeBeanID = beans.first(where: { !$0.isArchived })?.id
        }
        save()
    }

    func setGitHub(projectID: UUID, remote: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].githubRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }
}

private struct WorkspaceFile: Codable {
    var projects: [Project]
    var beans: [Bean]
    var activeProjectID: UUID?
    var activeBeanID: UUID?
}
