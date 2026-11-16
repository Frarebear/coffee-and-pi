import AppKit
import SwiftUI

/// Full first-launch walkthrough: engines → connect 1-by-1 → Beans / Projects / Coffee Shop.
struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: OnboardingStore
    @StateObject private var installer = LocalRuntimeInstaller()

    @State private var apiKeyDraft = ""
    @State private var useOAuth = true
    @State private var hfLink = "ggml-org/gemma-3-1b-it-GGUF:Q4_K_M"

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                Divider().overlay(CPTheme.border)
                ScrollView {
                    content
                        .padding(28)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                }
                Divider().overlay(CPTheme.border)
                footer
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { installer.refresh() }
    }

    // MARK: - Chrome

    private var background: some View {
        LinearGradient(
            colors: [
                CPTheme.bg,
                CPTheme.espresso.opacity(0.85),
                CPTheme.bg,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            CoffeeBagMark()
                .frame(width: 22, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Coffee & Pi")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(CPTheme.text)
                Text(store.step.title)
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.muted)
            }
            Spacer()
            Text(store.progressLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CPTheme.muted)
            Button("Skip setup") { store.skipAll() }
                .buttonStyle(.plain)
                .foregroundStyle(CPTheme.muted)
                .font(.system(size: 12))
                .disabled(store.isBusy)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch store.step {
        case .welcome: welcomeStep
        case .chooseEngines: enginesStep
        case .connect: connectStep
        case .tourBean: tourBeanStep
        case .tourProject: tourProjectStep
        case .tourShop: tourShopStep
        case .done: doneStep
        }
    }

    private var footer: some View {
        HStack {
            if store.step != .welcome && store.step != .done {
                Button("Back") { goBack() }
                    .disabled(store.isBusy)
            }
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch store.step {
        case .welcome:
            Button("Get started") { store.goNextFromWelcome() }
                .keyboardShortcut(.defaultAction)
        case .chooseEngines:
            Button(store.selectedEngines.isEmpty ? "Continue without engines" : "Connect selected") {
                store.goNextFromEngines()
            }
            .keyboardShortcut(.defaultAction)
        case .connect:
            EmptyView()
        case .tourBean, .tourProject, .tourShop:
            Button("Continue") { store.goNextTour() }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isBusy)
        case .done:
            Button("Open Coffee & Pi") { store.finish() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your Mac runs the shop.")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(CPTheme.text)
            Text("Coffee & Pi is a local AI workspace: Beans (agents), Projects (folders), and a Coffee Shop where Beans sit at tables and talk. Wire local models and/or cloud subs — then brew.")
                .font(.system(size: 14))
                .foregroundStyle(CPTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            tip("Phone pairing is coming later — skip that for now.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enginesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What do you want to connect?")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(CPTheme.text)
            Text("Pick one or more. We’ll set them up one at a time. You can add more later in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(CPTheme.muted)

            LazyVStack(spacing: 8) {
                ForEach(OnboardingStore.Engine.allCases) { engine in
                    engineRow(engine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func engineRow(_ engine: OnboardingStore.Engine) -> some View {
        let on = store.selectedEngines.contains(engine)
        return Button {
            if on { store.selectedEngines.remove(engine) }
            else { store.selectedEngines.insert(engine) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? CPTheme.accent : CPTheme.muted)
                    .font(.system(size: 18))
                Image(systemName: engine.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(CPTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CPTheme.text)
                    Text(engine.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(CPTheme.panel.opacity(on ? 1 : 0.7))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? CPTheme.accent.opacity(0.5) : CPTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var connectStep: some View {
        if let engine = store.currentConnectEngine {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect · \(engine.title)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(CPTheme.text)
                Text(engine.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(CPTheme.muted)

                Text("\(store.connectIndex + 1) of \(store.connectQueue.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CPTheme.muted)

                switch engine {
                case .local: localConnectPanel
                case .mlx: mlxConnectPanel
                case .cursor: cursorConnectPanel
                default: cloudConnectPanel(engine)
                }

                if let msg = store.statusMessage {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Skip this one") {
                        store.advanceAfterConnect()
                        apiKeyDraft = ""
                    }
                    .disabled(store.isBusy)
                    Spacer()
                    if engine != .cursor {
                        Button(store.isBusy ? "Working…" : "Continue") {
                            Task { await handleConnectContinue(engine) }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.isBusy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView()
                .onAppear { store.step = .tourBean }
        }
    }

    private var localConnectPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine("Pi", installer.check.piReady)
            statusLine("llama.cpp", installer.check.llamaReady)
            statusLine("llama-router", installer.check.routerReady)
            statusLine("models/presets", installer.check.presetsReady)
            statusLine("Pi ↔ llama.cpp auth", installer.check.llamaAuthReady)

            Text("Installs missing pieces only — won’t delete existing models or auth.")
                .font(.caption)
                .foregroundStyle(CPTheme.muted)

            Button(store.isBusy ? "Installing…" : "Install / repair local stack") {
                Task { await runLocalSetup() }
            }
            .disabled(store.isBusy)

            if installer.check.localOK {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Optional starter model (Hugging Face)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CPTheme.text)
                    TextField("owner/repo:QUANT", text: $hfLink)
                        .textFieldStyle(.roundedBorder)
                    Button("Download starter model") {
                        Task { await downloadStarter() }
                    }
                    .disabled(store.isBusy || hfLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(CPTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { installer.refresh() }
    }

    private var mlxConnectPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine("mlx-lm", installer.check.mlxReady)
            statusLine("Pi mlx provider", installer.check.mlxAuthReady)
            Text("MLX uses Apple Silicon GPU memory. After install, run `mlx_lm.server --model <HF-id>` (or brew services) when you want a model loaded. Port 8080 by default.")
                .font(.caption)
                .foregroundStyle(CPTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(store.isBusy ? "Installing…" : "Install / register MLX") {
                Task { await runMLXSetup() }
            }
            .disabled(store.isBusy)
        }
        .padding(12)
        .background(CPTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { installer.refresh() }
    }

    private var cursorConnectPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cursor isn’t an API provider here — it’s a Bean identity for Cursor-style coding and “Work with” transcript handoff from Cursor `.jsonl` files.")
                .font(.system(size: 13))
                .foregroundStyle(CPTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create Cursor Bean") {
                Task { await createCursorBean(); store.advanceAfterConnect() }
            }
            .disabled(store.isBusy)
        }
        .padding(12)
        .background(CPTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func cloudConnectPanel(_ engine: OnboardingStore.Engine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if isEngineConnected(engine) {
                Label("Already connected in ~/.pi/agent/auth.json", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(CPTheme.accent)
                    .font(.system(size: 13))
            }

            if engine == .openai {
                Picker("Method", selection: $useOAuth) {
                    Text("ChatGPT account").tag(true)
                    Text("API key").tag(false)
                }
                .pickerStyle(.segmented)
            } else if engine.acceptsAPIKey && engine.prefersOAuth {
                Picker("Method", selection: $useOAuth) {
                    Text("Account (browser)").tag(true)
                    Text("API key").tag(false)
                }
                .pickerStyle(.segmented)
            }

            if engine.acceptsAPIKey && (!engine.prefersOAuth || !useOAuth) {
                SecureField("API key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Text("Saved only to ~/.pi/agent/auth.json on this Mac.")
                    .font(.caption2)
                    .foregroundStyle(CPTheme.muted)
            }

            if engine.prefersOAuth && (useOAuth || !engine.acceptsAPIKey) {
                Text(engine == .openai
                      ? "Opens Terminal for ChatGPT sign-in (`pi auth login openai`). Pi stores that under the openai provider."
                      : "Opens Terminal for `pi auth login` — finish sign-in there, then hit Continue.")
                    .font(.caption)
                    .foregroundStyle(CPTheme.muted)
                Button("Open sign-in in Terminal") {
                    Task { await openOAuth(engine) }
                }
                .disabled(store.isBusy || oauthProviderID(for: engine) == nil)
            }
        }
        .padding(12)
        .background(CPTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            useOAuth = engine.prefersOAuth
            apiKeyDraft = ""
            installer.refresh()
        }
    }

    private func isEngineConnected(_ engine: OnboardingStore.Engine) -> Bool {
        if let pid = engine.piProviderID, installer.hasProvider(pid) { return true }
        return engine.alternatePiProviderIDs.contains { installer.hasProvider($0) }
    }

    private func oauthProviderID(for engine: OnboardingStore.Engine) -> String? {
        // ChatGPT subscription OAuth is `openai` in current Pi (see openaiProvider oauth label).
        engine.piProviderID
    }

    private var tourBeanStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Beans")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(CPTheme.text)
            Text("A Bean is an agent. The name is the job — “Shipper”, “Baseball Bot”, “Pi”. No long brief required.")
                .font(.system(size: 13))
                .foregroundStyle(CPTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("First bean name", text: $store.beanNameDraft)
                .textFieldStyle(.roundedBorder)

            Button("Create bean & open chat") {
                Task { await createFirstBean() }
            }
            .disabled(store.beanNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)

            tip("You can skip and create Beans anytime from the sidebar + menu.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tourProjectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Projects")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(CPTheme.text)
            Text("A Project is a folder on disk. Beans and chats can live inside a project (cwd for tools) or float loose.")
                .font(.system(size: 13))
                .foregroundStyle(CPTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Add a project folder…") {
                addProjectFolder()
            }

            tip("Self-edit Beans can change Coffee & Pi itself when pointed at this repo.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tourShopStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The Coffee Shop")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(CPTheme.text)
            Text("The shop is a floor plan: Beans walk, sit at tables, and talk to each other. House lobby = loose Beans; each Project gets its own café. Seat the house to spin up Local / Codex / Cursor Beans.")
                .font(.system(size: 13))
                .foregroundStyle(CPTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open the Coffee Shop") {
                app.openShop(projectID: nil)
            }

            tip("Phone: Settings → Devices → enable remotes, open the phone UI URL, enter the pair code.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You’re set.")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(CPTheme.text)
            Text("Sidebar: Projects, Beans, Chats. Bottom: Coffee Shop + Settings. Replay this walkthrough anytime from Settings → Onboarding.")
                .font(.system(size: 13))
                .foregroundStyle(CPTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func goBack() {
        switch store.step {
        case .chooseEngines: store.step = .welcome
        case .connect:
            if store.connectIndex > 0 {
                store.connectIndex -= 1
                store.statusMessage = nil
            } else {
                store.step = .chooseEngines
            }
        case .tourBean: store.step = store.connectQueue.isEmpty ? .chooseEngines : .connect
        case .tourProject: store.step = .tourBean
        case .tourShop: store.step = .tourProject
        default: break
        }
    }

    private func runLocalSetup() async {
        store.isBusy = true
        store.statusMessage = nil
        do {
            try await installer.setupLocalStack { msg in
                store.statusMessage = msg
            }
            await app.router.ensureRunning()
            app.syncProfilesFromRouter()
            app.rebuildAvailableModels()
            app.auth.reload()
            store.statusMessage = "Local stack ready"
        } catch {
            store.statusMessage = error.localizedDescription
        }
        store.isBusy = false
    }

    private func runMLXSetup() async {
        store.isBusy = true
        do {
            try await installer.setupMLX { msg in
                store.statusMessage = msg
            }
            app.auth.reload()
            await app.refreshModelsFromPi()
        } catch {
            store.statusMessage = error.localizedDescription
        }
        store.isBusy = false
    }

    private func downloadStarter() async {
        store.isBusy = true
        store.statusMessage = "Downloading…"
        do {
            let id = try await app.downloadHuggingFaceModel(hfLink)
            store.statusMessage = "Downloaded \(id)"
        } catch {
            store.statusMessage = error.localizedDescription
        }
        store.isBusy = false
    }

    private func openOAuth(_ engine: OnboardingStore.Engine) async {
        guard let pid = oauthProviderID(for: engine) else { return }
        store.isBusy = true
        do {
            if installer.resolvePiPath() == nil {
                try await installer.setupLocalStack { store.statusMessage = $0 }
            }
            try installer.openInteractivePiLogin(provider: pid)
            store.statusMessage = "Finish sign-in in Terminal, then Continue"
        } catch {
            store.statusMessage = error.localizedDescription
        }
        store.isBusy = false
    }

    private func handleConnectContinue(_ engine: OnboardingStore.Engine) async {
        store.isBusy = true
        defer { store.isBusy = false }
        do {
            switch engine {
            case .local:
                if !installer.check.localOK {
                    try await installer.setupLocalStack { store.statusMessage = $0 }
                    await app.router.ensureRunning()
                    app.syncProfilesFromRouter()
                    app.rebuildAvailableModels()
                }
            case .mlx:
                if !installer.check.mlxOK {
                    try await installer.setupMLX { store.statusMessage = $0 }
                }
                app.auth.reload()
            case .cursor:
                await createCursorBean()
            default:
                if let pid = engine.piProviderID {
                    if engine.acceptsAPIKey && (!engine.prefersOAuth || !useOAuth) {
                        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else {
                            store.statusMessage = "Paste an API key, or skip"
                            return
                        }
                        if installer.resolvePiPath() == nil {
                            try await installer.setupLocalStack { store.statusMessage = $0 }
                        }
                        try installer.saveAPIKey(provider: pid, key: key)
                        apiKeyDraft = ""
                    } else if !isEngineConnected(engine) {
                        store.statusMessage = "Sign in first (or skip)"
                        return
                    }
                    app.auth.reload()
                    await app.refreshModelsFromPi()
                }
            }
            store.advanceAfterConnect()
        } catch {
            store.statusMessage = error.localizedDescription
        }
    }

    private func createFirstBean() async {
        let name = store.beanNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.isBusy = true
        await app.onboardNewBean(name: name, projectID: nil, selfEdit: true, accentHue: store.beanHue)
        store.isBusy = false
        store.statusMessage = "Created \(name)"
    }

    private func createCursorBean() async {
        if app.projects.beans.contains(where: { $0.name == "Cursor" && !$0.isArchived }) {
            store.statusMessage = "Cursor Bean already exists"
            return
        }
        await app.onboardNewBean(name: "Cursor", projectID: nil, selfEdit: true, accentHue: 0.55)
        if var bean = app.projects.beans.first(where: { $0.name == "Cursor" }) {
            bean.defaultProvider = "cursor"
            app.projects.updateBean(bean)
        }
        store.statusMessage = "Cursor Bean ready"
    }

    private func addProjectFolder() {
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
            store.statusMessage = "Added \(url.lastPathComponent)"
            Task {
                if let remote = await app.github.detectRemote(at: url.path),
                   let id = app.projects.activeProjectID {
                    app.projects.setGitHub(projectID: id, remote: remote)
                }
            }
        }
    }

    // MARK: - Bits

    private func statusLine(_ label: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? CPTheme.accent : CPTheme.muted)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(CPTheme.text)
            Spacer()
            Text(ok ? "Ready" : "Needed")
                .font(.caption)
                .foregroundStyle(CPTheme.muted)
        }
    }

    private func tip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(CPTheme.muted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CPTheme.composer.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
