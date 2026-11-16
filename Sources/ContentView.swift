import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
            } detail: {
                switch app.detailPane {
                case .chat:
                    ChatView()
                case .shop:
                    CoffeeShopView()
                        .environmentObject(app.presence)
                case .settings:
                    SettingsView()
                }
            }
            .background(CPTheme.bg)
            .preferredColorScheme(.dark)
            .opacity(app.onboarding.isPresented ? 0.25 : 1)
            .allowsHitTesting(!app.onboarding.isPresented)

            if app.onboarding.isPresented {
                OnboardingView(store: app.onboarding)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.onboarding.isPresented)
    }
}

// MARK: - Sidebar (Projects / Beans / Chats — in or out of projects)

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @State private var beanNameDraft = ""
    @State private var beanLookHue: Double = Double.random(in: 0.05...0.12)
    @State private var newBeanProjectID: UUID? = nil
    @State private var showNewBeanSheet = false
    @FocusState private var searchFocused: Bool

    private var queryActive: Bool {
        !app.sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    Task { await app.newChat() }
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPTheme.text)

                Spacer()

                Menu {
                    Button("New project…") { addProject() }
                    Button("New bean") { promptNewBean(projectID: nil) }
                    Button("New loose chat") {
                        app.projects.selectProject(nil)
                        app.projects.selectBean(nil)
                        Task { await app.newChat(projectID: nil, beanID: nil) }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(CPTheme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                TextField("Search beans & chats", text: $app.sidebarQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(CPTheme.text)
                    .focused($searchFocused)
                if queryActive {
                    Button {
                        app.sidebarQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CPTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(CPTheme.composer)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            RouterBadge(status: app.router.status)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            Text(app.router.slotsLabel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(CPTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if queryActive {
                        searchResults
                    } else {
                        sectionHeader("Projects", expanded: app.expandProjects) {
                            app.expandProjects.toggle()
                        } add: {
                            addProject()
                        }
                        if app.expandProjects {
                            ForEach(app.projects.projects) { project in
                                ProjectRow(project: project) {
                                    promptNewBean(projectID: project.id)
                                }
                            }
                        }

                        sectionHeader("Beans", expanded: app.expandLooseBeans) {
                            app.expandLooseBeans.toggle()
                        } add: {
                            promptNewBean(projectID: nil)
                        }
                        if app.expandLooseBeans {
                            ForEach(app.projects.looseBeans()) { bean in
                                BeanRow(bean: bean, indent: 14)
                            }
                        }

                        sectionHeader("Chats", expanded: app.expandLooseChats) {
                            app.expandLooseChats.toggle()
                        } add: {
                            app.projects.selectProject(nil)
                            app.projects.selectBean(nil)
                            Task { await app.newChat(projectID: nil, beanID: nil) }
                        }
                        if app.expandLooseChats {
                            ForEach(app.orphanChats()) { thread in
                                ChatRow(thread: thread, leading: 14)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Divider().overlay(CPTheme.border)

            Button {
                app.openShop(projectID: nil)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 13))
                    Text("Coffee Shop")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if app.detailPane == .shop && app.shopProjectID == nil {
                        Circle().fill(CPTheme.accent).frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(app.detailPane == .shop && app.shopProjectID == nil ? CPTheme.text : CPTheme.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("House lobby — loose Beans & chats")

            Button {
                app.detailPane = .settings
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                    Text("Settings")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if app.detailPane == .settings {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(app.detailPane == .settings ? CPTheme.text : CPTheme.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(CPTheme.panel)
        .sheet(isPresented: $showNewBeanSheet) {
            NewBeanSheet(
                name: $beanNameDraft,
                accentHue: $beanLookHue,
                projectID: newBeanProjectID,
                onCancel: {
                    beanNameDraft = ""
                    newBeanProjectID = nil
                    showNewBeanSheet = false
                },
                onCreate: { name, hue in
                    let projectID = newBeanProjectID
                    beanNameDraft = ""
                    newBeanProjectID = nil
                    showNewBeanSheet = false
                    Task {
                        await app.onboardNewBean(
                            name: name,
                            projectID: projectID,
                            selfEdit: true,
                            accentHue: hue
                        )
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let beans = app.projects.beans.filter {
            !$0.isArchived && app.matchesSidebarQuery($0.name)
        }
        let chats = app.threads.filter {
            !$0.isArchived && (
                app.matchesSidebarQuery($0.title)
                    || app.matchesSidebarQuery($0.preview)
                    || app.chatBeanLabel($0).map { app.matchesSidebarQuery($0) } == true
            )
        }
        let projects = app.projects.projects.filter {
            app.matchesSidebarQuery($0.name) || app.matchesSidebarQuery($0.path)
        }

        if projects.isEmpty && beans.isEmpty && chats.isEmpty {
            Text("No matches")
                .font(.system(size: 12))
                .foregroundStyle(CPTheme.muted)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        } else {
            if !projects.isEmpty {
                Text("Projects")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                ForEach(projects) { project in
                    ProjectRow(project: project) {
                        promptNewBean(projectID: project.id)
                    }
                }
            }
            if !beans.isEmpty {
                Text("Beans")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                ForEach(beans) { bean in
                    BeanRow(bean: bean, indent: 14)
                }
            }
            if !chats.isEmpty {
                Text("Chats")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                ForEach(chats) { thread in
                    ChatRow(thread: thread, leading: 14)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(
        _ title: String,
        expanded: Bool,
        toggle: @escaping () -> Void,
        add: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                }
                .foregroundStyle(CPTheme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPTheme.muted)
            .help("Add")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func promptNewBean(projectID: UUID?) {
        newBeanProjectID = projectID
        beanNameDraft = ""
        beanLookHue = Double.random(in: 0.05...0.12)
        showNewBeanSheet = true
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        if panel.runModal() == .OK, let url = panel.url {
            app.projects.addProject(name: url.lastPathComponent, path: url.path)
            if let id = app.projects.activeProjectID {
                app.expandedProjectIDs.insert(id)
            }
            Task {
                if let remote = await app.github.detectRemote(at: url.path),
                   let id = app.projects.activeProjectID {
                    app.projects.setGitHub(projectID: id, remote: remote)
                }
                await app.newChat()
            }
        }
    }
}

struct ProjectRow: View {
    @EnvironmentObject private var app: AppModel
    let project: Project
    var onAddBean: () -> Void

    private var expanded: Bool {
        app.expandedProjectIDs.contains(project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                app.toggleProjectExpanded(project.id)
                app.projects.selectProject(project.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(CPTheme.muted)
                        .frame(width: 10)
                    CoffeeBagMark()
                        .frame(width: 14, height: 16)
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CPTheme.text)
                        .lineLimit(1)
                    Spacer()
                    if project.hasGitHub {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                            .foregroundStyle(CPTheme.muted)
                    }
                    Button {
                        app.openShop(projectID: project.id)
                    } label: {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        app.detailPane == .shop && app.shopProjectID == project.id
                            ? CPTheme.accent : CPTheme.muted
                    )
                    .help("Open \(project.name) coffee shop")
                    Menu {
                        Button("Open coffee shop") { app.openShop(projectID: project.id) }
                        Button("New bean in project") { onAddBean() }
                        Button("New chat in project") {
                            app.projects.selectProject(project.id)
                            app.projects.selectBean(nil)
                            Task { await app.newChat(projectID: project.id, beanID: nil) }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(CPTheme.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Open coffee shop") {
                    app.openShop(projectID: project.id)
                }
                Button("New chat in project") {
                    app.projects.selectProject(project.id)
                    app.projects.selectBean(nil)
                    Task { await app.newChat(projectID: project.id, beanID: nil) }
                }
                Button("New bean…") { onAddBean() }
                if project.hasGitHub {
                    Button("Open on GitHub") { app.github.openRepo(project.githubRemote) }
                } else {
                    Button("Detect GitHub remote") {
                        Task {
                            if let remote = await app.github.detectRemote(at: project.path) {
                                app.projects.setGitHub(projectID: project.id, remote: remote)
                            }
                        }
                    }
                }
            }

            if expanded {
                let beans = app.projects.beans(in: project.id)
                let chats = app.chats(in: project.id)

                if !beans.isEmpty {
                    Text("Beans")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CPTheme.muted)
                        .padding(.leading, 28)
                        .padding(.top, 4)
                    ForEach(beans) { bean in
                        BeanRow(bean: bean, indent: 28)
                    }
                }

                Text("Chats")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                    .padding(.leading, 28)
                    .padding(.top, beans.isEmpty ? 4 : 8)
                if chats.isEmpty {
                    Text("No chats yet")
                        .font(.system(size: 11))
                        .foregroundStyle(CPTheme.muted.opacity(0.8))
                        .padding(.leading, 36)
                        .padding(.vertical, 2)
                } else {
                    ForEach(chats) { thread in
                        ChatRow(thread: thread, leading: 36)
                    }
                }
            }
        }
    }
}

struct BeanRow: View {
    @EnvironmentObject private var app: AppModel
    let bean: Bean
    var indent: CGFloat = 22

    private var isActive: Bool {
        app.projects.activeBeanID == bean.id && app.detailPane == .chat
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            BeanMark(hue: bean.accentHue)
                .frame(width: 22, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bean.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CPTheme.text)
                    if bean.allowsSelfEdit {
                        Text("edit")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CPTheme.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(CPTheme.composer)
                            .clipShape(Capsule())
                    }
                }
                Text(app.preview(for: bean))
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("New chat with \(bean.name)") {
                    Task { await app.newChat(projectID: bean.projectID, beanID: bean.id) }
                }
                Divider()
                Button("Archive") {
                    app.archiveBean(bean.id)
                }
                Button("Delete…", role: .destructive) {
                    app.deleteBean(bean.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Bean actions")
        }
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? CPTheme.composer : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { app.selectBean(bean.id) }
        .contextMenu {
            Button("New chat with \(bean.name)") {
                Task { await app.newChat(projectID: bean.projectID, beanID: bean.id) }
            }
            if let active = app.activeThread, active.isTable,
               !active.participantBeanIDs.contains(bean.id) {
                Button("Invite \(bean.name) to table") {
                    Task { await app.inviteBean(bean.id, to: active.id) }
                }
            }
            let others = app.projects.beans.filter { $0.id != bean.id }
            if let partner = others.first {
                Button("Start table with \(partner.name)") {
                    Task {
                        _ = await app.createTableChat(
                            beanIDs: [bean.id, partner.id],
                            projectID: bean.projectID ?? partner.projectID
                        )
                    }
                }
            }
            if bean.projectID != nil {
                Button("Move bean out of project") {
                    app.projects.moveBean(bean.id, toProject: nil)
                }
            } else {
                ForEach(app.projects.projects) { project in
                    Button("Move into \(project.name)") {
                        app.projects.moveBean(bean.id, toProject: project.id)
                        app.expandedProjectIDs.insert(project.id)
                    }
                }
            }
            Divider()
            Button("Archive") {
                app.archiveBean(bean.id)
            }
            Button("Delete…", role: .destructive) {
                app.deleteBean(bean.id)
            }
        }
    }
}

struct ChatRow: View {
    @EnvironmentObject private var app: AppModel
    let thread: ChatThread
    var leading: CGFloat = 60

    private var isSelected: Bool {
        app.activeThreadID == thread.id && app.detailPane == .chat
    }

    private var accentHue: Double {
        app.projects.bean(id: thread.beanID)?.accentHue ?? 0.08
    }

    var body: some View {
        Button {
            app.selectThread(thread.id)
        } label: {
            HStack(spacing: 8) {
                ChatMark(hue: accentHue, busy: thread.isBusy)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(isSelected ? CPTheme.text : CPTheme.muted)
                        .lineLimit(1)
                    if let bean = app.chatBeanLabel(thread) {
                        Text(bean)
                            .font(.system(size: 10))
                            .foregroundStyle(CPTheme.muted.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(RelativeTime.format(thread.updatedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(CPTheme.muted.opacity(0.8))
                Menu {
                    Button("Archive") {
                        app.archiveThread(thread.id)
                    }
                    Button("Delete…", role: .destructive) {
                        app.deleteThread(thread.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CPTheme.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Chat actions")
            }
            .padding(.leading, leading)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? CPTheme.composer.opacity(0.85) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Archive") {
                app.archiveThread(thread.id)
            }
            Button("Delete…", role: .destructive) {
                app.deleteThread(thread.id)
            }
        }
    }
}

/// Coffee-bean mark (not a Grok face).
struct BeanMark: View {
    let hue: Double

    var body: some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.55, brightness: 0.42),
                            Color(hue: hue, saturation: 0.65, brightness: 0.22),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .rotationEffect(.degrees(-18))
            Capsule()
                .stroke(Color.black.opacity(0.35), lineWidth: 1.2)
                .frame(width: 1.5, height: 16)
                .rotationEffect(.degrees(-18))
        }
    }
}

/// Chat bubble mark — paired with BeanMark in lists / shop floor.
struct ChatMark: View {
    var hue: Double = 0.08
    var busy: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.45, brightness: 0.72),
                            Color(hue: hue, saturation: 0.55, brightness: 0.42),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if busy {
                Circle()
                    .fill(CPTheme.accent)
                    .frame(width: 5, height: 5)
                    .offset(x: 1, y: 1)
            }
        }
    }
}

/// Grokbot-style create: choose a name (+ look). Name is the job.
private struct NewBeanSheet: View {
    @Binding var name: String
    @Binding var accentHue: Double
    let projectID: UUID?
    var onCancel: () -> Void
    var onCreate: (String, Double) -> Void

    private let lookHues: [Double] = [0.06, 0.08, 0.10, 0.02, 0.55, 0.35, 0.75, 0.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose a name")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(CPTheme.text)

            Text(projectID == nil
                 ? "The name is the job — like “Baseball Bot” or “Shipper”. That’s enough to start."
                 : "Name the bean for this project. The name is the job — no long brief needed.")
                .font(.system(size: 13))
                .foregroundStyle(CPTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Bean name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(10)
                .background(CPTheme.composer)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("Pick my look")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                HStack(spacing: 10) {
                    ForEach(lookHues, id: \.self) { hue in
                        Button {
                            accentHue = hue
                        } label: {
                            BeanMark(hue: hue)
                                .frame(width: 28, height: 34)
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            abs(accentHue - hue) < 0.001 ? CPTheme.text.opacity(0.7) : Color.clear,
                                            lineWidth: 1.5
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed, accentHue)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(CPTheme.panel)
    }
}

/// Project mark — a little sack of beans (replaces the blue folder).
struct CoffeeBagMark: View {
    var body: some View {
        ZStack(alignment: .top) {
            // Sack body
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: 0.08, saturation: 0.55, brightness: 0.48),
                            Color(hue: 0.07, saturation: 0.65, brightness: 0.28),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 12, height: 12)
                .padding(.top, 3)
            // Gathered top / tie
            Capsule()
                .fill(Color(hue: 0.08, saturation: 0.4, brightness: 0.55))
                .frame(width: 8, height: 3)
            // Tiny beans peeking out
            HStack(spacing: 1.5) {
                Capsule()
                    .fill(Color(hue: 0.07, saturation: 0.55, brightness: 0.22))
                    .frame(width: 2.5, height: 4)
                    .rotationEffect(.degrees(-20))
                Capsule()
                    .fill(Color(hue: 0.09, saturation: 0.5, brightness: 0.3))
                    .frame(width: 2.5, height: 4)
                    .rotationEffect(.degrees(15))
            }
            .padding(.top, 6)
        }
    }
}

enum RelativeTime {
    static func format(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

struct RouterBadge: View {
    let status: RouterStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(CPTheme.muted)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CPTheme.composer)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var color: Color {
        switch status {
        case .running: return .green
        case .starting: return .yellow
        case .error: return .red
        case .stopped: return .gray
        }
    }

    private var label: String {
        switch status {
        case .running(let models):
            return models.isEmpty ? "Router · idle" : "Router · \(models.joined(separator: ", "))"
        case .starting: return "Router · starting…"
        case .stopped: return "Router · stopped"
        case .error(let msg): return "Router · \(msg)"
        }
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let thread = app.activeThread {
                if thread.isTable {
                    TableHeader(thread: thread)
                        .padding(.horizontal, 28)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                } else {
                    SoloChatHeader(thread: thread)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                }

                if let notice = app.rebuildNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(CPTheme.accent)
                        Text(notice)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CPTheme.text)
                        Spacer()
                        Button {
                            app.rebuildNotice = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CPTheme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(CPTheme.composer)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(thread.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(28)
                    }
                    .onChange(of: thread.messages.last?.text) { _, _ in
                        if let id = thread.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                }

                if let err = thread.lastError ?? app.bootError {
                    ChatErrorBanner(
                        message: err,
                        isRetrying: err.hasPrefix("Retrying"),
                        onDismiss: {
                            if let idx = app.threads.firstIndex(where: { $0.id == thread.id }) {
                                app.threads[idx].lastError = nil
                            }
                            if app.bootError == err { app.bootError = nil }
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }

                ComposerView()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            } else {
                ContentUnavailableView("No chat", systemImage: "bubble.left", description: Text("Pick a bean or start a new chat."))
            }
        }
        .background(CPTheme.bg)
    }
}

struct SoloChatHeader: View {
    @EnvironmentObject private var app: AppModel
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 10) {
            if let bean = app.projects.bean(id: thread.beanID) {
                BeanMark(hue: bean.accentHue)
                    .frame(width: 18, height: 24)
            } else {
                ChatMark(busy: thread.isBusy)
                    .frame(width: 18, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CPTheme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let label = app.chatBeanLabel(thread) {
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CPTheme.muted)
                    }
                    if let model = thread.selectedModel {
                        Text("·")
                            .foregroundStyle(CPTheme.muted.opacity(0.5))
                        Text(model.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(CPTheme.muted)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(RelativeTime.format(thread.updatedAt))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(CPTheme.muted)
        }
    }
}

struct TableHeader: View {
    @EnvironmentObject private var app: AppModel
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 10) {
            Button {
                app.detailPane = .shop
            } label: {
                Image(systemName: "cup.and.saucer.fill")
                    .foregroundStyle(CPTheme.accent)
            }
            .buttonStyle(.plain)
            .help("Open Coffee Shop")

            Text(thread.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CPTheme.text)
            Spacer()
            ForEach(thread.participantBeanIDs, id: \.self) { id in
                if let bean = app.projects.bean(id: id) {
                    HStack(spacing: 4) {
                        BeanMark(hue: bean.accentHue).frame(width: 14, height: 18)
                        Text(bean.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CPTheme.text)
                        Text(bean.providerChip)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(CPTheme.accent.opacity(0.9))
                        Text(app.presence.state(for: id).label)
                            .font(.system(size: 9))
                            .foregroundStyle(CPTheme.muted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(CPTheme.composer)
                    .clipShape(Capsule())
                }
            }

            Menu {
                ForEach(app.projects.beans.filter { !thread.participantBeanIDs.contains($0.id) }) { bean in
                    Button("Invite \(bean.name)") {
                        Task { await app.inviteBean(bean.id, to: thread.id) }
                    }
                }
            } label: {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.muted)
            }
            .menuStyle(.borderlessButton)
            .help("Invite Bean to table")
        }
    }
}

struct MessageBubble: View {
    @EnvironmentObject private var app: AppModel
    let message: ChatMessage
    @State private var thinkingExpanded = false

    private var speakerBean: Bean? {
        guard let id = message.speakerBeanID else { return nil }
        return app.projects.bean(id: id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let bean = speakerBean {
                BeanMark(hue: bean.accentHue)
                    .frame(width: 18, height: 24)
                    .padding(.top, 2)
            } else if message.role == .user {
                Image(systemName: "person.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.muted)
                    .frame(width: 18, height: 24)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(speakerLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(speakerBean.map { Color(hue: $0.accentHue, saturation: 0.45, brightness: 0.75) } ?? CPTheme.muted)
                    if let chip = speakerBean?.providerChip {
                        Text(chip)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(CPTheme.muted)
                    }
                    if message.isStreaming, let status = statusLabel {
                        StreamingStatusChip(label: status)
                    }
                }

                if !message.thinkingText.isEmpty || (message.isStreaming && message.streamPhase == .thinking) {
                    DisclosureGroup(isExpanded: thinkingExpandedBinding) {
                        Text(message.thinkingText.isEmpty ? "…" : message.thinkingText)
                            .font(.system(size: 12.5, weight: .regular, design: .default))
                            .foregroundStyle(CPTheme.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    } label: {
                        Text(message.isStreaming && message.streamPhase == .thinking ? "Thinking" : "Thought")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(CPTheme.accent.opacity(0.85))
                    }
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 14.5, weight: .regular, design: .default))
                        .foregroundStyle(message.isError ? Color.red.opacity(0.9) : CPTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if message.isStreaming, message.thinkingText.isEmpty, statusLabel == nil {
                    Text("…")
                        .font(.system(size: 14.5, weight: .regular, design: .default))
                        .foregroundStyle(CPTheme.muted)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, speakerBean == nil ? 0 : 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(speakerBean != nil ? CPTheme.composer.opacity(0.35) : Color.clear)
        )
        .onChange(of: message.streamPhase) { _, phase in
            if phase == .thinking { thinkingExpanded = true }
        }
        .onAppear {
            if message.isStreaming && message.streamPhase == .thinking {
                thinkingExpanded = true
            }
        }
    }

    private var thinkingExpandedBinding: Binding<Bool> {
        Binding(
            get: { thinkingExpanded || (message.isStreaming && message.streamPhase == .thinking && !message.thinkingText.isEmpty) },
            set: { thinkingExpanded = $0 }
        )
    }

    private var statusLabel: String? {
        guard message.isStreaming else { return nil }
        if message.streamPhase == .retrying {
            if let detail = message.activeToolName, !detail.isEmpty { return detail }
            return "Retrying…"
        }
        if message.streamPhase == .tooling, let tool = message.activeToolName, !tool.isEmpty {
            return tool.hasPrefix("Using ") || tool.hasSuffix("…") ? tool : "Using \(tool)…"
        }
        let label = message.streamPhase.statusLabel
        return label.isEmpty ? "Starting…" : label
    }

    private var speakerLabel: String {
        if message.role == .user, message.speakerBeanID == nil { return "You" }
        if message.role == .system { return "System" }
        if let bean = speakerBean { return bean.name }
        return message.role == .assistant ? "Pi" : "You"
    }
}

private struct StreamingStatusChip: View {
    let label: String
    @State private var pulse = false

    private var isRetry: Bool { label.hasPrefix("Retrying") }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isRetry ? Color.orange.opacity(0.9) : CPTheme.accent)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 1 : 0.35)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(isRetry ? Color.orange.opacity(0.95) : CPTheme.accent)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(CPTheme.composer.opacity(0.9))
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct ChatErrorBanner: View {
    let message: String
    var isRetrying: Bool = false
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isRetrying ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isRetrying ? Color.orange.opacity(0.9) : Color.red.opacity(0.85))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(isRetrying ? "Retrying" : "Something went wrong")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRetrying ? Color.orange.opacity(0.95) : Color.red.opacity(0.9))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if !isRetrying {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CPTheme.muted)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isRetrying ? Color.orange.opacity(0.12) : Color.red.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isRetrying ? Color.orange.opacity(0.25) : Color.red.opacity(0.25), lineWidth: 1)
        )
    }
}

struct ComposerView: View {
    @EnvironmentObject private var app: AppModel
    @FocusState private var focused: Bool
    @StateObject private var dictation = SpeechDictation()

    private var slashMatches: [SlashCommand] {
        app.filteredSlashCommands(for: app.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !slashMatches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slashMatches.prefix(8)) { cmd in
                        Button {
                            app.applySlashCommand(cmd)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(cmd.menuLabel)
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(CPTheme.text)
                                if let desc = cmd.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 11))
                                        .foregroundStyle(CPTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(cmd.source)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(CPTheme.muted.opacity(0.8))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(CPTheme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(CPTheme.border, lineWidth: 1)
                )
            }

            HStack(alignment: .top, spacing: 10) {
                TextField(
                    composerPlaceholder,
                    text: $app.draft,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .foregroundStyle(CPTheme.text)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit {
                        if let only = slashMatches.first, slashMatches.count == 1,
                           app.draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/\(only.name)"
                            || app.draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/\(only.name)") {
                            // Enter on a slash pick → run it
                        }
                        Task { await app.send() }
                    }

                Button {
                    dictation.toggle(base: app.draft) { text in
                        app.draft = text
                    }
                } label: {
                    Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(dictation.isListening ? Color.red.opacity(0.9) : CPTheme.muted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(dictation.isListening ? "Stop dictation" : "Dictate")
                .padding(.top, 2)

                if app.activeThread?.isBusy == true {
                    Button {
                        Task { await app.abort() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(CPTheme.text)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                } else {
                    Button {
                        Task { await app.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CPTheme.muted : CPTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.top, 1)
                }
            }

            if let err = dictation.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.85))
            }

            HStack(spacing: 14) {
                Menu {
                    Text(app.router.slotsLabel)
                    if app.availableModels.isEmpty {
                        Text("No models — check router / subscriptions")
                    }
                    let local = app.availableModels.filter { $0.provider == "llama.cpp" }
                    let cloud = app.availableModels.filter { $0.provider != "llama.cpp" }
                    if !local.isEmpty {
                        Section("Local · \(app.router.slotsLabel)") {
                            ForEach(local) { model in
                                Button {
                                    Task { await app.setModel(model) }
                                } label: {
                                    HStack {
                                        Text(model.menuLabel)
                                        if app.activeThread?.selectedModel?.id == model.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !cloud.isEmpty {
                        Section("Cloud") {
                            ForEach(cloud) { model in
                                Button {
                                    Task { await app.setModel(model) }
                                } label: {
                                    HStack {
                                        Text(model.menuLabel)
                                        if app.activeThread?.selectedModel?.id == model.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Refresh models") {
                        Task {
                            await app.router.refresh()
                            await app.refreshCloudCatalog()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(app.activeThread?.selectedModel?.displayName ?? "Model")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(CPTheme.muted)
                }
                .menuStyle(.borderlessButton)

                Menu {
                    ForEach(ThinkingLevel.allCases) { level in
                        Button {
                            Task { await app.setThinking(level) }
                        } label: {
                            HStack {
                                Text(level.label)
                                if app.activeThread?.thinkingLevel == level {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Think · \(app.activeThread?.thinkingLevel.label ?? "Off")")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(CPTheme.muted)
                }
                .menuStyle(.borderlessButton)

                if app.activeThread?.isTable == true {
                    Button("Talk among yourselves") {
                        Task { await app.beansKeepTalking() }
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(CPTheme.muted)
                    .buttonStyle(.plain)
                    .disabled(app.activeThread?.isBusy == true)
                    .help("Run another table turn")

                    Button {
                        app.detailPane = .shop
                    } label: {
                        Image(systemName: "cup.and.saucer")
                            .font(.system(size: 12))
                            .foregroundStyle(CPTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Coffee Shop floor")
                }

                Menu {
                    let others = app.threads.filter { $0.id != app.activeThreadID }
                    if others.isEmpty {
                        Text("No other chats to link")
                    } else {
                        ForEach(others) { thread in
                            Button("Work with · \(thread.title)") {
                                guard let target = app.activeThreadID else { return }
                                Task { await app.workWith(threadID: thread.id, into: target) }
                            }
                        }
                    }
                    Divider()
                    Button("Open transcript…") {
                        pickTranscriptForHandoff()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Work with")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(CPTheme.muted)
                }
                .menuStyle(.borderlessButton)

                Spacer()
            }
        }
        .padding(14)
        .background(CPTheme.composer)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(CPTheme.border, lineWidth: 1)
        )
        .onAppear { focused = true }
    }

    private var composerPlaceholder: String {
        if app.activeThread?.isTable == true {
            return "Message the table… (@Bean to invite)"
        }
        if let name = app.projects.activeBean?.name {
            return "Message \(name)…"
        }
        if let thread = app.activeThread, let label = app.chatBeanLabel(thread) {
            return "Message \(label)…"
        }
        return "Message bean…"
    }

    private func pickTranscriptForHandoff() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.json, .plainText]
        if let jsonl = UTType(filenameExtension: "jsonl") { types.append(jsonl) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Pick a Cursor agent transcript (.jsonl)"
        panel.prompt = "Work with"
        guard panel.runModal() == .OK, let url = panel.url, let target = app.activeThreadID else { return }
        Task { await app.workWithTranscriptFile(at: url, into: target) }
    }
}

// MARK: - Settings (detail pane; opened from sidebar bottom)

private enum SettingsTab: String, CaseIterable, Identifiable {
    case models, cloud, devices, more
    var id: String { rawValue }
    var label: String {
        switch self {
        case .models: return "Models"
        case .cloud: return "Cloud"
        case .devices: return "Devices"
        case .more: return "More"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var tab: SettingsTab = .models
    @State private var selectedCloudProvider: CloudProviderOption = .openrouter
    @State private var cloudAuthIsAPIKey = true
    @State private var cloudAPIKey = ""
    @State private var statusMessage: String?
    @State private var githubDraft = ""
    @State private var hfLink = ""
    @State private var selectedModelID: String?
    @State private var draftProfile: LocalModelProfile?
    @State private var modelStatus: String?
    @State private var botInstructionsDraft = ""
    @State private var nodeNameDraft = ""
    @State private var publicHostDraft = ""
    @State private var pairCodeVisible = ""
    @State private var showAdvancedModel = false
    @State private var modelsMaxDraft = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    app.detailPane = .chat
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPTheme.muted)
                Spacer()
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(CPTheme.text)
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .models: modelsTab
                    case .cloud: cloudTab
                    case .devices: devicesTab
                    case .more: moreTab
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .background(CPTheme.bg)
        .onAppear {
            app.auth.reload()
            app.syncProfilesFromRouter()
            nodeNameDraft = app.node.pairing.nodeName
            publicHostDraft = app.node.pairing.publicHost
            modelsMaxDraft = app.router.modelsMax
            if selectedModelID == nil {
                selectModel(app.router.routerModels.first?.id)
            }
            if let bean = app.projects.activeBean {
                botInstructionsDraft = bean.instructions
            }
            Task {
                await app.github.refreshAuth()
                await app.refreshUsage()
                await app.refreshCloudCatalog()
            }
        }
    }

    // MARK: Models

    @ViewBuilder
    private var modelsTab: some View {
        settingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routerLabel)
                        .foregroundStyle(CPTheme.text)
                    Text(app.hardware.label)
                        .font(.caption)
                        .foregroundStyle(CPTheme.muted)
                    Text(app.router.slotsLabel + " loaded")
                        .font(.caption)
                        .foregroundStyle(CPTheme.muted)
                }
                Spacer()
                Button("Refresh") {
                    Task {
                        await app.router.refresh()
                        app.syncProfilesFromRouter()
                        app.rebuildAvailableModels()
                    }
                }
                Button("Restart") {
                    Task {
                        do {
                            try await app.router.restartRouter()
                            app.syncProfilesFromRouter()
                            app.rebuildAvailableModels()
                        } catch {
                            modelStatus = error.localizedDescription
                        }
                    }
                }
            }
            HStack {
                Text("Concurrent slots")
                Spacer()
                Picker("", selection: $modelsMaxDraft) {
                    ForEach([1, 2, 3, 4, 6, 8], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .labelsHidden()
                .frame(width: 70)
                Button("Apply") {
                    Task {
                        do {
                            try await app.router.setModelsMax(modelsMaxDraft)
                            modelStatus = "Slots → \(app.router.modelsMax)"
                        } catch {
                            modelStatus = error.localizedDescription
                        }
                    }
                }
                .disabled(modelsMaxDraft == app.router.modelsMax)
            }
            Text("When several small models fit, raise slots so they stay loaded together.")
                .font(.caption)
                .foregroundStyle(CPTheme.muted)
        }

        settingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Download")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                HStack {
                    TextField("huggingface.co/… or owner/repo:Q4_K_M", text: $hfLink)
                        .textFieldStyle(.roundedBorder)
                    Button(app.router.isDownloading ? "…" : "Add") {
                        Task { await downloadHF() }
                    }
                    .disabled(hfLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.router.isDownloading)
                }
                if let progress = app.router.downloadProgress {
                    ProgressView(value: progress.ratio ?? 0, total: 1)
                    Text(progress.message).font(.caption).foregroundStyle(CPTheme.muted)
                }
                if let err = app.router.lastDownloadError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }

        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                if app.router.routerModels.isEmpty {
                    Text("No local models yet — paste a HF link above.")
                        .foregroundStyle(CPTheme.muted)
                } else {
                    Picker("Model", selection: Binding(
                        get: { selectedModelID ?? app.router.routerModels.first?.id ?? "" },
                        set: { selectModel($0) }
                    )) {
                        ForEach(app.router.routerModels) { m in
                            Text(m.loaded ? "\(m.id) · loaded" : m.id).tag(m.id)
                        }
                    }
                }

                if let draft = draftProfile {
                    HStack {
                        Text("Context")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { draft.ctxSize },
                            set: { newValue in
                                draftProfile?.ctxSize = newValue
                                if newValue == LocalModelProfile.autoCtxSize {
                                    Task { await probeAutoCtx() }
                                }
                            }
                        )) {
                            ForEach(LocalModelProfile.ctxSizes, id: \.self) { n in
                                Text(LocalModelProfile.ctxLabel(n, fitted: draft.fittedCtxSize)).tag(n)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 140)
                    }
                    Toggle("Autocompaction", isOn: Binding(
                        get: { draftProfile?.autoCompaction ?? true },
                        set: { draftProfile?.autoCompaction = $0 }
                    ))
                    DisclosureGroup("Advanced", isExpanded: $showAdvancedModel) {
                        modelKnobsEditor(draft: Binding(
                            get: { draftProfile! },
                            set: { draftProfile = $0 }
                        ), compact: true)
                    }
                    .tint(CPTheme.muted)

                    HStack {
                        Button("Save & apply") { Task { await saveDraft(reload: true) } }
                            .buttonStyle(.borderedProminent)
                        Button("Load") {
                            Task {
                                guard let id = draftProfile?.id else { return }
                                do {
                                    try await app.router.loadModel(id)
                                    app.rebuildAvailableModels()
                                    modelStatus = "Loaded \(id)"
                                } catch {
                                    modelStatus = error.localizedDescription
                                }
                            }
                        }
                    }
                }

                if let modelStatus {
                    Text(modelStatus).font(.caption).foregroundStyle(CPTheme.muted)
                }
            }
        }
    }

    // MARK: Cloud

    @ViewBuilder
    private var cloudTab: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Providers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                if app.auth.providers.filter({ $0.name != "llama.cpp" }).isEmpty {
                    Text("None yet — add one below.")
                        .foregroundStyle(CPTheme.muted)
                } else {
                    ForEach(app.auth.providers.filter { $0.name != "llama.cpp" }) { p in
                        HStack {
                            Text(p.name)
                            Text(p.type)
                                .font(.caption)
                                .foregroundStyle(CPTheme.muted)
                            Spacer()
                            Button("Logout") {
                                Task { try? await app.auth.logout(provider: p.name) }
                            }
                        }
                    }
                }

                Picker("Provider", selection: $selectedCloudProvider) {
                    ForEach(CloudProviderOption.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: selectedCloudProvider) { _, next in
                    cloudAPIKey = ""
                    switch next.auth {
                    case .apiKeyOnly:
                        cloudAuthIsAPIKey = true
                    case .oauthOnly:
                        cloudAuthIsAPIKey = false
                    case .oauthOrApiKey:
                        break // keep current choice
                    }
                }

                if selectedCloudProvider.supportsOAuth && selectedCloudProvider.supportsAPIKey {
                    Picker("Sign-in", selection: $cloudAuthIsAPIKey) {
                        Text("API key").tag(true)
                        Text("Account (OAuth)").tag(false)
                    }
                    .pickerStyle(.segmented)
                } else if selectedCloudProvider.supportsOAuth {
                    Text("Uses account sign-in in Terminal.")
                        .font(.caption)
                        .foregroundStyle(CPTheme.muted)
                } else {
                    Text("API key only — stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(CPTheme.muted)
                }

                if cloudAuthIsAPIKey && selectedCloudProvider.supportsAPIKey {
                    SecureField(selectedCloudProvider.apiKeyPlaceholder, text: $cloudAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save API key") {
                        Task { await saveCloudAPIKey() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if selectedCloudProvider.supportsOAuth {
                    Button("Sign in with \(selectedCloudProvider.displayName)…") {
                        Task { await startCloudOAuth() }
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack {
                    Button("Refresh catalog") {
                        Task {
                            await app.refreshCloudCatalog()
                            let n = app.availableModels.filter { $0.provider != "llama.cpp" }.count
                            statusMessage = "\(n) cloud model(s) in picker"
                        }
                    }
                    Spacer()
                }

                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(CPTheme.muted)
                }
            }
        }

        settingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Usage")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CPTheme.muted)
                    Spacer()
                    Button("Refresh") { Task { await app.refreshUsage() } }
                        .disabled(app.usage.isRefreshingOpenRouter)
                }
                if let or = app.usage.openRouter, or.error == nil {
                    Text("OpenRouter · \(or.remainingLabel)")
                    Text(String(format: "Today $%.2f · Month $%.2f", or.usageDaily, or.usageMonthly))
                        .font(.caption)
                        .foregroundStyle(CPTheme.muted)
                } else if app.auth.openRouterAPIKey == nil {
                    Text("Import openrouter for live credits.")
                        .font(.caption)
                        .foregroundStyle(CPTheme.muted)
                }
                ForEach(app.usage.stats.prefix(6)) { row in
                    HStack {
                        Text(row.provider)
                        Spacer()
                        Text("\(row.messages) turns · ~\(row.estimatedTokens.formatted()) tok")
                            .font(.caption)
                            .foregroundStyle(CPTheme.muted)
                    }
                }
            }
        }
    }

    // MARK: Devices

    @ViewBuilder
    private var devicesTab: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allow remote devices", isOn: Binding(
                    get: { app.node.pairing.remoteEnabled },
                    set: { app.node.setEnabled($0) }
                ))
                HStack {
                    TextField("This Mac’s name", text: $nodeNameDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        app.node.pairing.setNodeName(nodeNameDraft)
                        if app.node.isListening { app.node.start() }
                    }
                }

                if app.node.isListening {
                    Text("Port \(app.node.pairing.port) · \(app.node.reachabilityHosts.joined(separator: ", ").nilIfEmpty ?? "localhost")")
                        .font(.caption)
                        .foregroundStyle(CPTheme.muted)

                    if let url = app.node.mobileClientURL {
                        HStack {
                            Text("Phone UI")
                                .font(.caption)
                                .foregroundStyle(CPTheme.muted)
                            Text(url)
                                .font(.caption)
                                .foregroundStyle(CPTheme.text)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                            Button("Open") {
                                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                            }
                        }
                    }

                    if !app.node.offLANAddresses.isEmpty {
                        Text("Off-LAN (Tailscale) · \(app.node.offLANAddresses.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(CPTheme.accent)
                    } else {
                        Text("Off-LAN: join this Mac to Tailscale (or set a tunnel host below). No Coffee & Pi account.")
                            .font(.caption)
                            .foregroundStyle(CPTheme.muted)
                    }

                    HStack {
                        TextField("Public host (optional)", text: $publicHostDraft)
                            .textFieldStyle(.roundedBorder)
                            .help("Tailscale MagicDNS or Cloudflare Tunnel hostname")
                        Button("Save") {
                            app.node.pairing.setPublicHost(publicHostDraft)
                            app.node.refreshAddresses()
                            if app.node.isListening { app.node.start() }
                        }
                    }

                    HStack(alignment: .top, spacing: 16) {
                        QRCodeView(string: app.node.pairQRString(), size: 140)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pair code")
                                .font(.caption)
                                .foregroundStyle(CPTheme.muted)
                            Text(pairDisplayCode)
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Button("New code") {
                                pairCodeVisible = app.node.refreshPairChallenge().code
                            }
                            Text("Scan QR or open the phone UI URL and enter this code.")
                                .font(.caption)
                                .foregroundStyle(CPTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ForEach(app.node.pairing.pendingAuths.filter { $0.status == .pending && $0.expiresAt >= Date() }) { auth in
                        HStack {
                            Text("\(auth.deviceName) · \(auth.userCode)")
                            Spacer()
                            Button("Deny") { app.node.pairing.denyDeviceAuth(id: auth.id) }
                            Button("Allow") { _ = app.node.pairing.approveDeviceAuth(id: auth.id) }
                        }
                    }
                    ForEach(app.node.pairing.pairedDevices) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                app.node.pairing.revokeDevice(id: device.id)
                            }
                        }
                    }
                } else if app.node.pairing.remoteEnabled {
                    Text(app.node.lastError ?? "Starting…")
                        .font(.caption)
                        .foregroundStyle(CPTheme.muted)
                }
            }
            .onAppear {
                if app.node.pairing.remoteEnabled {
                    pairCodeVisible = (app.node.pairing.activeChallenge ?? app.node.refreshPairChallenge()).code
                }
            }
            .onChange(of: app.node.pairing.remoteEnabled) { _, on in
                if on { pairCodeVisible = app.node.refreshPairChallenge().code }
            }
        }
    }

    // MARK: More

    @ViewBuilder
    private var moreTab: some View {
        if let bean = app.projects.activeBean {
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bean · \(bean.name)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CPTheme.muted)
                    TextEditor(text: $botInstructionsDraft)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 140)
                        .border(CPTheme.border)
                    Button("Save prompt") {
                        var updated = bean
                        updated.instructions = botInstructionsDraft
                        app.projects.updateBean(updated)
                        statusMessage = "Saved"
                    }
                }
                .onAppear { botInstructionsDraft = bean.instructions }
                .onChange(of: bean.id) { _, _ in botInstructionsDraft = bean.instructions }
            }
        }

        if let project = app.projects.activeProject {
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project · \(project.name)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CPTheme.muted)
                    Text(project.path).font(.caption).foregroundStyle(CPTheme.muted)
                    if project.hasGitHub {
                        HStack {
                            Text(project.githubRemote)
                            Button("Open") { app.github.openRepo(project.githubRemote) }
                            Button("Clear") { app.projects.setGitHub(projectID: project.id, remote: "") }
                        }
                    } else {
                        HStack {
                            TextField("owner/repo", text: $githubDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Connect") {
                                app.projects.setGitHub(projectID: project.id, remote: githubDraft)
                                githubDraft = ""
                            }
                            Button("Detect") {
                                Task {
                                    if let remote = await app.github.detectRemote(at: project.path) {
                                        app.projects.setGitHub(projectID: project.id, remote: remote)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        settingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Archived")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPTheme.muted)
                let archivedBeans = app.projects.archivedBeans()
                let archivedChats = app.archivedChats()
                if archivedBeans.isEmpty && archivedChats.isEmpty {
                    Text("Nothing archived.")
                        .foregroundStyle(CPTheme.muted)
                } else {
                    ForEach(archivedBeans) { bean in
                        HStack {
                            Text(bean.name)
                            Spacer()
                            Button("Restore") { app.unarchiveBean(bean.id) }
                            Button("Delete", role: .destructive) { app.deleteBean(bean.id) }
                        }
                    }
                    ForEach(archivedChats) { thread in
                        HStack {
                            Text(thread.title).lineLimit(1)
                            Spacer()
                            Button("Restore") { app.unarchiveThread(thread.id) }
                            Button("Delete", role: .destructive) { app.deleteThread(thread.id) }
                        }
                    }
                }
            }
        }

        settingsCard {
            Button("Replay onboarding…") { app.onboarding.replay() }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CPTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CPTheme.border, lineWidth: 1)
            )
    }

    private var pairDisplayCode: String {
        if !pairCodeVisible.isEmpty { return pairCodeVisible }
        return app.node.pairing.activeChallenge?.code ?? "------"
    }

    @ViewBuilder
    private func modelKnobsEditor(draft: Binding<LocalModelProfile>, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                HStack {
                    Text("Context length")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { draft.wrappedValue.ctxSize },
                        set: { newValue in
                            draft.wrappedValue.ctxSize = newValue
                            if newValue == LocalModelProfile.autoCtxSize {
                                Task { await probeAutoCtx() }
                            }
                        }
                    )) {
                        ForEach(LocalModelProfile.ctxSizes, id: \.self) { n in
                            Text(LocalModelProfile.ctxLabel(n, fitted: draft.wrappedValue.fittedCtxSize)).tag(n)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160)
                }
            }

            HStack {
                Text("K cache")
                Spacer()
                Picker("", selection: Binding(
                    get: { draft.wrappedValue.cacheTypeK },
                    set: { draft.wrappedValue.cacheTypeK = $0 }
                )) {
                    ForEach(LocalModelProfile.cacheTypes, id: \.self) { q in
                        Text(q).tag(q)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            HStack {
                Text("V cache")
                Spacer()
                Picker("", selection: Binding(
                    get: { draft.wrappedValue.cacheTypeV },
                    set: { draft.wrappedValue.cacheTypeV = $0 }
                )) {
                    ForEach(LocalModelProfile.cacheTypes, id: \.self) { q in
                        Text(q).tag(q)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            if !compact {
                Toggle("Autocompaction", isOn: Binding(
                    get: { draft.wrappedValue.autoCompaction },
                    set: { draft.wrappedValue.autoCompaction = $0 }
                ))
            }

            Text("System prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { draft.wrappedValue.systemPrompt },
                set: { draft.wrappedValue.systemPrompt = $0 }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 70, maxHeight: 120)
            .border(CPTheme.border)
        }
        .padding(.top, 6)
    }

    private func selectModel(_ id: String?) {
        selectedModelID = id
        if let id {
            var p = app.modelProfiles.profile(for: id)
            if p.modelPath == nil {
                p.modelPath = app.router.routerModels.first(where: { $0.id == id })?.modelPath
            }
            if let live = app.router.routerModels.first(where: { $0.id == id })?.ctxSize, live > 0, p.isAutoCtx {
                p.fittedCtxSize = live
            }
            draftProfile = p
            // Always re-probe Auto per selected model — fits differ by weights/architecture.
            if p.isAutoCtx {
                Task { await probeAutoCtx() }
            } else {
                modelStatus = "Fixed \(p.ctxSize.formatted()) tokens for \(p.id)"
            }
        } else {
            draftProfile = nil
        }
    }

    private func probeAutoCtx() async {
        guard var draft = draftProfile, draft.isAutoCtx else { return }
        let modelID = draft.id
        modelStatus = "Fitting \(modelID) to \(HardwareContextFitter.HardwareInfo.current().label)…"
        draft = await app.enrichWithFittedCtx(draft)
        // Still looking at the same model?
        guard draftProfile?.id == modelID else { return }
        draftProfile = draft
        app.modelProfiles.upsert(draft)
        if let fitted = draft.fittedCtxSize {
            modelStatus = "\(modelID) · Auto ≈ \(fitted.formatted()) tokens (this model only)"
        } else {
            modelStatus = "\(modelID) · fit-params unavailable; llama.cpp will fit at load"
        }
    }

    private func ctxHelpText(for profile: LocalModelProfile) -> String {
        let hw = HardwareContextFitter.HardwareInfo.current().label
        if profile.isAutoCtx {
            if let fitted = profile.fittedCtxSize {
                return "Per model on \(hw) · this one ≈ \(fitted.formatted()) tokens"
            }
            return "Per model — fits free Metal memory on \(hw) for this model only"
        }
        return "Fixed for this model. Autocompaction still summarizes older turns near the limit."
    }

    private func saveDraft(reload: Bool) async {
        guard let draft = draftProfile else { return }
        modelStatus = reload ? "Applying (router restart)…" : "Saving…"
        do {
            try await app.saveModelProfile(draft, reload: reload)
            modelStatus = reload ? "Applied \(draft.id)" : "Saved \(draft.id)"
        } catch {
            modelStatus = error.localizedDescription
        }
    }

    private func saveCloudAPIKey() async {
        let key = cloudAPIKey
        do {
            try app.auth.saveAPIKey(key, for: selectedCloudProvider)
            cloudAPIKey = ""
            statusMessage = "Saved \(selectedCloudProvider.displayName) key — refreshing catalog…"
            await app.refreshCloudCatalog()
            let cloudCount = app.availableModels.filter { $0.provider != "llama.cpp" }.count
            statusMessage = "Saved \(selectedCloudProvider.displayName) · \(cloudCount) cloud model(s) in picker"
            await app.refreshUsage()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func startCloudOAuth() async {
        do {
            try app.auth.loginWithOAuth(provider: selectedCloudProvider)
            statusMessage = "Finish sign-in in Terminal, then come back — catalog refreshes on return."
            app.auth.reload()
            await app.refreshCloudCatalog()
            let cloudCount = app.availableModels.filter { $0.provider != "llama.cpp" }.count
            if cloudCount > 0 {
                statusMessage = "\(selectedCloudProvider.displayName) · \(cloudCount) cloud model(s) in picker"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func downloadHF() async {
        let raw = hfLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        modelStatus = nil
        do {
            let id = try await app.downloadHuggingFaceModel(raw)
            hfLink = ""
            selectModel(id)
            modelStatus = "Downloaded \(id)"
            statusMessage = "Downloaded \(id)"
        } catch {
            modelStatus = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private var routerLabel: String {
        switch app.router.status {
        case .running(let m): return m.isEmpty ? "Running" : "Running (\(m.joined(separator: ", ")))"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .error(let e): return "Error: \(e)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
