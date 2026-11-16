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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
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
                        Task { await app.send() }
                    }

                if app.activeThread?.isBusy == true {
                    Button {
                        Task { await app.abort() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(CPTheme.text)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await app.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CPTheme.muted : CPTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 14) {
                Menu {
                    if app.availableModels.isEmpty {
                        Text("No models — check router / subscriptions")
                    }
                    ForEach(app.availableModels) { model in
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
                    Divider()
                    Button("Refresh models") {
                        Task {
                            await app.router.refresh()
                            app.rebuildAvailableModels()
                            await app.refreshModelsFromPi()
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

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var providerName = ""
    @State private var useAPIKey = true
    @State private var statusMessage: String?
    @State private var githubDraft = ""
    @State private var hfLink = ""
    @State private var selectedModelID: String?
    @State private var draftProfile: LocalModelProfile?
    @State private var modelStatus: String?
    @State private var botInstructionsDraft = ""
    @State private var nodeNameDraft = ""
    @State private var pairCodeVisible = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button {
                        app.detailPane = .chat
                    } label: {
                        Label("Back to chat", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CPTheme.muted)
                    Spacer()
                }

                Text("Settings")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(CPTheme.text)

                GroupBox("Onboarding") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Replay the first-launch walkthrough (engines, local/MLX install, Beans, Projects, Coffee Shop). Does not wipe your data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Replay onboarding…") {
                            app.onboarding.replay()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                devicesSection

                GroupBox("Local router") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(routerLabel)
                        Text("Hardware · \(app.hardware.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Auto ctx uses llama-fit-params (fallback: RAM heuristic).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Refresh") {
                                Task {
                                    await app.router.refresh()
                                    app.syncProfilesFromRouter()
                                    app.rebuildAvailableModels()
                                }
                            }
                            Button("Restart router") {
                                Task {
                                    do {
                                        try await app.router.restartRouter()
                                        app.syncProfilesFromRouter()
                                        app.rebuildAvailableModels()
                                        statusMessage = "Router restarted"
                                    } catch {
                                        statusMessage = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Download from Hugging Face") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste a huggingface.co link or owner/repo[:QUANT]. Defaults to Q4_K_M.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://huggingface.co/… or owner/repo:Q4_K_M", text: $hfLink)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button(app.router.isDownloading ? "Downloading…" : "Download") {
                                Task { await downloadHF() }
                            }
                            .disabled(hfLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.router.isDownloading)
                            if app.router.isDownloading {
                                Button("Cancel") {
                                    Task { await app.router.cancelDownload() }
                                }
                            }
                        }
                        if let progress = app.router.downloadProgress {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(progress.message)
                                    .font(.caption)
                                ProgressView(value: progress.ratio ?? 0, total: 1)
                                    .progressViewStyle(.linear)
                                if let detail = progress.detail {
                                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let err = app.router.lastDownloadError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Local models") {
                    VStack(alignment: .leading, spacing: 12) {
                        if app.router.routerModels.isEmpty {
                            Text("No router models yet — download one above.")
                                .foregroundStyle(.secondary)
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

                        if draftProfile != nil {
                            modelKnobsEditor(draft: Binding(
                                get: { draftProfile! },
                                set: { draftProfile = $0 }
                            ))
                        }

                        if let modelStatus {
                            Text(modelStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if let bean = app.projects.activeBean {
                    GroupBox("Active bean · instructions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(bean.projectID.flatMap { pid in app.projects.projects.first { $0.id == pid }?.name }.map { "\($0) / \(bean.name)" } ?? bean.name)
                                .font(.headline)
                            Text("Optional. The name already carries the job — refine here only if you want. Per-model prompt above is appended for local models.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $botInstructionsDraft)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 100, maxHeight: 180)
                                .border(CPTheme.border)
                            Button("Save bean prompt") {
                                var updated = bean
                                updated.instructions = botInstructionsDraft
                                app.projects.updateBean(updated)
                                statusMessage = "Saved bean prompt"
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                    .onAppear { botInstructionsDraft = bean.instructions }
                    .onChange(of: bean.id) { _, _ in botInstructionsDraft = bean.instructions }
                }

                if let project = app.projects.activeProject {
                    GroupBox("Active project · GitHub") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(project.name).font(.headline)
                            Text(project.path).font(.caption).foregroundStyle(.secondary)
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
                            if let login = app.github.loggedInLogin {
                                Text("gh · \(login)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }

                GroupBox("Usage") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Subs + OpenRouter")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(app.usage.isRefreshingOpenRouter ? "Refreshing…" : "Refresh") {
                                Task { await app.refreshUsage() }
                            }
                            .disabled(app.usage.isRefreshingOpenRouter)
                        }

                        if let or = app.usage.openRouter {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OpenRouter\(or.label.map { " · \($0)" } ?? "")")
                                    .font(.headline)
                                if let err = or.error {
                                    Text(err).font(.caption).foregroundStyle(.red)
                                } else {
                                    Text(or.remainingLabel)
                                    Text(String(format: "Today $%.2f · Week $%.2f · Month $%.2f",
                                                or.usageDaily, or.usageWeekly, or.usageMonthly))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if app.auth.openRouterAPIKey == nil {
                            Text("Import openrouter to see live credit usage.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if app.usage.stats.isEmpty {
                            Text("Local turn counts show up here after you chat.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(app.usage.stats) { row in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.provider)
                                        Text(row.kindLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(row.messages) turns")
                                        Text("~\(row.estimatedTokens.formatted()) tok")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Imported subscriptions") {
                    VStack(alignment: .leading, spacing: 8) {
                        if app.auth.providers.isEmpty {
                            Text("No providers in ~/.pi/agent/auth.json yet. Local llama.cpp still works.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(app.auth.providers) { p in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(p.name)
                                        Text(p.type).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Logout") {
                                        Task { try? await app.auth.logout(provider: p.name) }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Import provider") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Provider (openai, anthropic, openrouter, …)", text: $providerName)
                            .textFieldStyle(.roundedBorder)
                        Toggle("API key login", isOn: $useAPIKey)
                        Button("Import via Pi auth") {
                            Task {
                                do {
                                    try await app.auth.login(
                                        provider: providerName.trimmingCharacters(in: .whitespacesAndNewlines),
                                        apiKey: useAPIKey
                                    )
                                    statusMessage = "Imported \(providerName)"
                                    providerName = ""
                                    await app.refreshModelsFromPi()
                                } catch {
                                    statusMessage = error.localizedDescription
                                }
                            }
                        }
                        .disabled(providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let statusMessage {
                            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Archived") {
                    VStack(alignment: .leading, spacing: 10) {
                        let archivedBeans = app.projects.archivedBeans()
                        let archivedChats = app.archivedChats()
                        if archivedBeans.isEmpty && archivedChats.isEmpty {
                            Text("Nothing archived. Use ⋯ on a bean or chat to archive.")
                                .foregroundStyle(.secondary)
                        } else {
                            if !archivedBeans.isEmpty {
                                Text("Beans").font(.caption).foregroundStyle(.secondary)
                                ForEach(archivedBeans) { bean in
                                    HStack {
                                        Text(bean.name)
                                        Spacer()
                                        Button("Restore") { app.unarchiveBean(bean.id) }
                                        Button("Delete…", role: .destructive) { app.deleteBean(bean.id) }
                                    }
                                }
                            }
                            if !archivedChats.isEmpty {
                                Text("Chats").font(.caption).foregroundStyle(.secondary)
                                ForEach(archivedChats) { thread in
                                    HStack {
                                        Text(thread.title)
                                            .lineLimit(1)
                                        Spacer()
                                        Button("Restore") { app.unarchiveThread(thread.id) }
                                        Button("Delete…", role: .destructive) { app.deleteThread(thread.id) }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Self-edit") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Self-edit beans run in a project folder and can change Coffee & Pi itself.")
                        Text("Rebuild: Scripts/rebuild-and-relaunch.sh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(28)
        }
        .background(CPTheme.bg)
        .onAppear {
            app.auth.reload()
            app.syncProfilesFromRouter()
            nodeNameDraft = app.node.pairing.nodeName
            if selectedModelID == nil {
                selectModel(app.router.routerModels.first?.id)
            }
            Task {
                await app.github.refreshAuth()
                await app.refreshUsage()
            }
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        GroupBox("Devices") {
            VStack(alignment: .leading, spacing: 12) {
                Text("This Mac is your server. The phone is a thin client — every chat/model request goes through this computer’s API (Pi + models stay here). Pair with QR or a device code — no Coffee & Pi account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Allow remote devices", isOn: Binding(
                    get: { app.node.pairing.remoteEnabled },
                    set: { app.node.setEnabled($0) }
                ))

                HStack {
                    TextField("Node name", text: $nodeNameDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save name") {
                        app.node.pairing.setNodeName(nodeNameDraft)
                        if app.node.isListening {
                            app.node.start() // republish Bonjour name
                        }
                    }
                }

                if app.node.isListening {
                    Text("Listening on port \(app.node.pairing.port) · \(app.node.lanAddresses.joined(separator: ", ").nilIfEmpty ?? "localhost")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let err = app.node.lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 8) {
                            QRCodeView(string: app.node.pairQRString(), size: 160)
                            Text("Scan with the Coffee & Pi app")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pair code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(pairDisplayCode)
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Button("New code") {
                                let c = app.node.refreshPairChallenge()
                                pairCodeVisible = c.code
                            }
                            Text("Expires in ~2 minutes. Enter this code on the other device, or scan the QR.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !app.node.pairing.pendingAuths.filter({ $0.status == .pending && $0.expiresAt >= Date() }).isEmpty {
                        Divider()
                        Text("Pending approvals").font(.headline)
                        ForEach(app.node.pairing.pendingAuths.filter { $0.status == .pending && $0.expiresAt >= Date() }) { auth in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(auth.deviceName)
                                    Text(auth.userCode)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Deny") { app.node.pairing.denyDeviceAuth(id: auth.id) }
                                Button("Allow") { _ = app.node.pairing.approveDeviceAuth(id: auth.id) }
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                    }

                    if !app.node.pairing.pairedDevices.isEmpty {
                        Divider()
                        Text("Paired").font(.headline)
                        ForEach(app.node.pairing.pairedDevices) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    app.node.pairing.revokeDevice(id: device.id)
                                }
                            }
                        }
                    }

                    Text("Off-LAN (away from home Wi‑Fi) comes next — pairing still stays on your machines, no central login.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if app.node.pairing.remoteEnabled {
                    Text(app.node.lastError ?? "Starting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .onAppear {
                if app.node.pairing.remoteEnabled {
                    let c = app.node.pairing.activeChallenge ?? app.node.refreshPairChallenge()
                    pairCodeVisible = c.code
                }
            }
            .onChange(of: app.node.pairing.remoteEnabled) { _, on in
                if on {
                    let c = app.node.refreshPairChallenge()
                    pairCodeVisible = c.code
                }
            }
        }
    }

    private var pairDisplayCode: String {
        if !pairCodeVisible.isEmpty { return pairCodeVisible }
        return app.node.pairing.activeChallenge?.code ?? "------"
    }

    @ViewBuilder
    private func modelKnobsEditor(draft: Binding<LocalModelProfile>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
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
                Text(ctxHelpText(for: draft.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("K cache quant")
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
                .frame(width: 120)
            }

            HStack {
                Text("V cache quant")
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
                .frame(width: 120)
            }

            Toggle("Autocompaction", isOn: Binding(
                get: { draft.wrappedValue.autoCompaction },
                set: { draft.wrappedValue.autoCompaction = $0 }
            ))

            Text("System prompt (per model)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { draft.wrappedValue.systemPrompt },
                set: { draft.wrappedValue.systemPrompt = $0 }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 90, maxHeight: 160)
            .border(CPTheme.border)

            HStack {
                Button("Save & apply") {
                    Task { await saveDraft(reload: true) }
                }
                .buttonStyle(.borderedProminent)
                Button("Save only") {
                    Task { await saveDraft(reload: false) }
                }
                Button("Load model") {
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
