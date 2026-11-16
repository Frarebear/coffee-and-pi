import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Playful coffee-shop diorama — Beans hang out, wander, and gossip.
struct CoffeeShopView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var presence: BeanPresenceStore
    @State private var selectedForTable: Set<UUID> = []
    @State private var idleOffsets: [UUID: CGPoint] = [:]
    @State private var pulse = false
    @State private var specialIndex = 0
    @State private var ticker: [String] = ["Shop just opened. Smells like espresso and ambition."]
    @State private var clinkTableID: Int?
    @State private var wanderTick = 0
    @State private var chatOffsets: [UUID: CGPoint] = [:]

    private let tables: [ShopTable] = [
        ShopTable(id: 0, x: 0.28, y: 0.44, label: "Window", vibe: "daydream"),
        ShopTable(id: 1, x: 0.72, y: 0.44, label: "Booth", vibe: "deep work"),
        ShopTable(id: 2, x: 0.28, y: 0.76, label: "Corner", vibe: "scheming"),
        ShopTable(id: 3, x: 0.72, y: 0.76, label: "Patio", vibe: "chaos"),
    ]

    private var scopedBeans: [Bean] { app.shopBeans() }
    private var scopedChats: [ChatThread] { app.shopChats() }
    private var scopedTables: [ChatThread] { app.shopTables() }

    private let specials = [
        "Today’s special: context window latte (extra tokens)",
        "Happy hour: merge conflicts half off",
        "Ask the barista about RAG cinnamon rolls",
        "Local roast · no cloud fee · tip your Beans",
        "Try the Cursor cortado (comes with a transcript)",
    ]

    var body: some View {
        VStack(spacing: 0) {
            shopToolbar
            GeometryReader { geo in
                ZStack {
                    room(in: geo.size)
                    ambientBits(in: geo.size)

                    ForEach(tables) { table in
                        tableNode(table, size: geo.size)
                    }

                    ForEach(scopedChats) { thread in
                        chatCard(thread, size: geo.size)
                    }

                    ForEach(scopedBeans) { bean in
                        beanActor(bean, size: geo.size)
                    }

                    if scopedBeans.isEmpty && scopedChats.isEmpty {
                        emptyPartyInvite
                    }

                    // Floating particles
                    ShopSparkles(active: pulse)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [CPTheme.accent.opacity(0.35), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            activityTicker
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.08, blue: 0.06),
                    Color(red: 0.07, green: 0.05, blue: 0.04),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            ensureIdleOffsets()
            ensureChatOffsets()
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
            startAmbientLoop()
            pushTicker(app.shopProjectID == nil
                       ? "House lobby open. Loose Beans & chats welcome."
                       : "\(app.shopTitle) café — project crew only.")
        }
        .onChange(of: app.projects.beans.map(\.id)) { _, _ in ensureIdleOffsets() }
        .onChange(of: scopedChats.map(\.id)) { _, _ in ensureChatOffsets() }
        .onChange(of: app.shopProjectID) { _, _ in
            idleOffsets = [:]
            chatOffsets = [:]
            ensureIdleOffsets()
            ensureChatOffsets()
            pushTicker(app.shopProjectID == nil
                       ? "Back at the House lobby."
                       : "Walked into \(app.shopTitle)’s shop.")
        }
        .onChange(of: presenceSnapshot) { _, _ in pushPresenceTicker() }
    }

    private var presenceSnapshot: String {
        presence.states
            .map { "\($0.key.uuidString.prefix(4)):\($0.value.label)" }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - Toolbar

    private var shopToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(CPTheme.accent.opacity(0.22))
                        .frame(width: 34, height: 34)
                        .scaleEffect(pulse ? 1.08 : 1.0)
                    Text("π")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(CPTheme.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.shopProjectID == nil ? "The Steam π · House" : "The Steam π · \(app.shopTitle)")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(CPTheme.text)
                    Text(statusLine)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(CPTheme.muted)
                }
            }

            Spacer()

            Menu {
                Button("House lobby") { app.openShop(projectID: nil) }
                if !app.projects.projects.isEmpty {
                    Divider()
                    ForEach(app.projects.projects) { project in
                        Button(project.name) { app.openShop(projectID: project.id) }
                    }
                }
            } label: {
                FunChipLabel(
                    title: app.shopProjectID == nil ? "House" : app.shopTitle,
                    icon: "building.2.fill"
                )
            }
            .menuStyle(.borderlessButton)
            .help("Switch coffee shops")

            if !selectedForTable.isEmpty {
                Text("\(selectedForTable.count) tagged for a table")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.15, green: 0.1, blue: 0.08))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(CPTheme.accent)
                    .clipShape(Capsule())
                    .transition(.scale.combined(with: .opacity))
            }

            FunChip(title: "Open shop", icon: "sparkles") {
                selectedForTable = Set(app.seatTheHouse(projectID: app.shopProjectID))
                pushTicker("Local, Codex, and Cursor just walked in. Someone’s buying.")
            }

            FunChip(title: "New chat", icon: "bubble.left.fill") {
                Task {
                    await app.newChat(projectID: app.shopProjectID, beanID: app.projects.activeBeanID)
                    // Stay in shop so the chat card appears on the floor.
                    app.detailPane = .shop
                    ensureChatOffsets()
                    pushTicker("Fresh chat dropped on the floor.")
                }
            }

            FunChip(title: "Seat ’em", icon: "chair.lounge.fill", hot: true) {
                Task {
                    let ids = Array(selectedForTable)
                    let seats = ids.count >= 2 ? ids : scopedBeans.prefix(2).map(\.id)
                    if await app.createTableChat(beanIDs: Array(seats), projectID: app.shopProjectID) != nil {
                        selectedForTable = []
                        // Keep shop open so you can watch them sit.
                        app.detailPane = .shop
                        pushTicker("Table claimed. Cups out. Debates incoming.")
                    }
                }
            }
            .disabled(scopedBeans.count < 2)
            .opacity(scopedBeans.count < 2 ? 0.4 : 1)

            Menu {
                ForEach(scopedBeans) { bean in
                    Button("Tag \(bean.name)") { selectedForTable.insert(bean.id) }
                }
            } label: {
                FunChipLabel(title: "Tag", icon: "hand.point.up.left.fill")
            }
            .menuStyle(.borderlessButton)

            Menu {
                let others = (scopedChats + scopedTables).filter { $0.id != app.activeThreadID }
                if others.isEmpty {
                    Text("Nothing to gossip about yet")
                } else {
                    ForEach(others) { thread in
                        Button(thread.title) {
                            guard let target = app.activeThreadID else { return }
                            Task { await app.workWith(threadID: thread.id, into: target) }
                            pushTicker("Passed notes across the shop.")
                        }
                    }
                }
                Divider()
                Button("Drop a Cursor transcript…") { pickTranscriptJSONL() }
            } label: {
                FunChipLabel(title: "Gossip", icon: "bubble.left.and.bubble.right.fill")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .animation(.spring(response: 0.35), value: selectedForTable.count)
    }

    private var statusLine: String {
        let beans = scopedBeans
        let speaking = beans.filter {
            if case .speaking = presence.state(for: $0.id) { return true }
            return false
        }.count
        if speaking > 0 {
            return "\(speaking) mid-rant · \(scopedTables.count) tables · \(scopedChats.count) chats"
        }
        let scope = app.shopProjectID == nil ? "lobby" : "project café"
        return "\(beans.count) Beans · \(scopedChats.count) chats · \(scope)"
    }

    private var activityTicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "radio.fill")
                .foregroundStyle(CPTheme.accent)
                .font(.system(size: 11))
            Text(ticker.last ?? "…")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(CPTheme.text.opacity(0.85))
                .lineLimit(1)
                .id(ticker.last)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            Spacer()
            Text(specials[specialIndex % specials.count])
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(CPTheme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(CPTheme.panel.opacity(0.95))
        .animation(.spring(response: 0.4), value: ticker.count)
    }

    private var emptyPartyInvite: some View {
        VStack(spacing: 14) {
            BeanBuddy(hue: 0.08, mood: .wave, scale: 1.4)
            Text(app.shopProjectID == nil ? "Lobby’s empty" : "\(app.shopTitle) is quiet")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(CPTheme.text)
            Text(app.shopProjectID == nil
                 ? "Open shop for Beans, or drop a loose chat on the floor."
                 : "Open shop for the project crew, or start a chat here.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(CPTheme.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                FunChip(title: "Open shop", icon: "door.left.hand.open", hot: true) {
                    selectedForTable = Set(app.seatTheHouse(projectID: app.shopProjectID))
                    pushTicker("Doors unlocked. Ambition entered.")
                }
                FunChip(title: "New chat", icon: "bubble.left.fill") {
                    Task {
                        await app.newChat(projectID: app.shopProjectID, beanID: nil)
                        app.detailPane = .shop
                        ensureChatOffsets()
                    }
                }
            }
        }
        .padding(28)
        .background(.ultraThinMaterial.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20)
    }

    // MARK: - Room scenery

    private func room(in size: CGSize) -> some View {
        ZStack {
            // Night café walls
            LinearGradient(
                colors: [
                    Color(red: 0.26, green: 0.16, blue: 0.12),
                    Color(red: 0.14, green: 0.09, blue: 0.07),
                    Color(red: 0.09, green: 0.06, blue: 0.05),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Window glow band
            VStack {
                HStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { _ in
                        shopWindow()
                    }
                }
                .padding(.horizontal, size.width * 0.14)
                .padding(.top, 18)
                Spacer()
            }

            // Floor
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.42, green: 0.28, blue: 0.16),
                            Color(red: 0.30, green: 0.19, blue: 0.11),
                            Color(red: 0.22, green: 0.14, blue: 0.09),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    Canvas { ctx, sz in
                        for i in 0..<18 {
                            var path = Path()
                            let y = CGFloat(i) * (sz.height / 18)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: sz.width, y: y))
                            ctx.stroke(path, with: .color(.black.opacity(0.07)), lineWidth: 1)
                        }
                    }
                }
                .frame(width: size.width - 24, height: size.height * 0.78)
                .position(x: size.width / 2, y: size.height * 0.58)
                .shadow(color: .black.opacity(0.4), radius: 16, y: -4)

            // Warm lamps
            ForEach([0.2, 0.5, 0.8], id: \.self) { x in
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [CPTheme.accent.opacity(pulse ? 0.22 : 0.12), .clear],
                            center: .center,
                            startRadius: 2,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 90)
                    .position(x: size.width * x, y: size.height * 0.22)
            }
        }
    }

    private func shopWindow() -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.65, blue: 0.75).opacity(0.55),
                        Color(red: 0.2, green: 0.25, blue: 0.35).opacity(0.6),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 58)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(red: 0.35, green: 0.22, blue: 0.14))
                    .frame(height: 5)
            }
    }

    private func ambientBits(in size: CGSize) -> some View {
        ZStack {
            // Neon OPEN
            Text("OPEN")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.35))
                .shadow(color: Color(red: 1.0, green: 0.35, blue: 0.25).opacity(pulse ? 0.9 : 0.4), radius: pulse ? 10 : 4)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 1.0, green: 0.45, blue: 0.35).opacity(0.7), lineWidth: 1.5)
                        .background(Color.black.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: 6)))
                )
                .position(x: size.width * 0.12, y: size.height * 0.11)
                .rotationEffect(.degrees(-8))

            // Chalkboard
            chalkboard
                .position(x: size.width * 0.88, y: size.height * 0.13)

            // Bar
            baristaBar(in: size)

            // Plant
            plant
                .position(x: size.width * 0.08, y: size.height * 0.88)

            // Record player / vibes corner
            vibesCorner
                .position(x: size.width * 0.92, y: size.height * 0.88)

            // Door
            door
                .position(x: size.width * 0.5, y: size.height * 0.95)
        }
    }

    private var chalkboard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SPECIALS")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
            Text(specials[specialIndex % specials.count])
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.92, green: 0.9, blue: 0.82))
                .lineLimit(3)
                .frame(width: 110, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.12, green: 0.18, blue: 0.14))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .rotationEffect(.degrees(3))
        .onTapGesture {
            withAnimation {
                specialIndex = (specialIndex + 1) % specials.count
            }
            pushTicker("Chalkboard updated. Marketing is a Bean now.")
        }
    }

    private func baristaBar(in size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.45, green: 0.28, blue: 0.16),
                            Color(red: 0.28, green: 0.16, blue: 0.10),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size.width * 0.62, height: 72)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Color(red: 0.85, green: 0.78, blue: 0.68).opacity(0.65))
                        .frame(height: 10)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)

            HStack(spacing: 16) {
                // Espresso machine with steam
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 0.12, green: 0.1, blue: 0.09))
                        .frame(width: 42, height: 40)
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(pulse ? 0.35 : 0.12))
                            .frame(width: 4, height: pulse ? 14 : 6)
                            .offset(x: CGFloat(i - 1) * 8, y: pulse ? -18 : -12)
                            .blur(radius: 1.5)
                    }
                    HStack(spacing: 3) {
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 4, height: 4)
                        Circle().fill(Color.orange.opacity(0.7)).frame(width: 4, height: 4)
                    }
                    .offset(y: 10)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("BAR")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(CPTheme.text)
                    Text("π·presso on tap")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(CPTheme.accent)
                }

                Spacer().frame(width: 20)

                // Cups stacked
                HStack(spacing: -4) {
                    ForEach(0..<4, id: \.self) { i in
                        BeanCup(hue: 0.08 + Double(i) * 0.03)
                            .offset(y: CGFloat(i % 2) * -3)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
        }
        .position(x: size.width * 0.48, y: size.height * 0.20)
    }

    private var plant: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    Ellipse()
                        .fill(Color(red: 0.2, green: 0.45 + Double(i) * 0.05, blue: 0.25).opacity(0.85))
                        .frame(width: 16, height: 22)
                        .rotationEffect(.degrees(Double(i) * 28 - 50))
                        .offset(y: -6)
                }
            }
            .frame(width: 40, height: 30)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.55, green: 0.28, blue: 0.2))
                .frame(width: 18, height: 14)
        }
    }

    private var vibesCorner: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.2, green: 0.15, blue: 0.12))
                    .frame(width: 36, height: 36)
                Circle()
                    .stroke(CPTheme.accent.opacity(0.5), lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(pulse ? 25 : -15))
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CPTheme.accent)
                    .offset(x: pulse ? 16 : 12, y: pulse ? -14 : -10)
                    .opacity(0.8)
            }
            Text("lo-fi")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(CPTheme.muted)
        }
    }

    private var door: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.18, green: 0.14, blue: 0.12))
                .frame(width: 50, height: 8)
            Text("come in / get out")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(CPTheme.muted)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.18, green: 0.14, blue: 0.12))
                .frame(width: 50, height: 8)
        }
    }

    // MARK: - Tables

    private func tableNode(_ table: ShopTable, size: CGSize) -> some View {
        let bound = tableThread(for: table)
        let occupied = bound != nil
        let seatCount = bound?.participantBeanIDs.count ?? 0
        let clinking = clinkTableID == table.id

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) {
                clinkTableID = table.id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                clinkTableID = nil
            }
            if let thread = bound {
                app.selectThread(thread.id)
                pushTicker("Leaned into \(table.label). Headphones off.")
            } else {
                Task {
                    var seats = Array(selectedForTable)
                    if seats.count < 2 {
                        seats = scopedBeans.prefix(2).map(\.id)
                    }
                    if await app.createTableChat(beanIDs: seats, projectID: app.shopProjectID) != nil {
                        selectedForTable = []
                        app.detailPane = .shop
                        pushTicker("\(table.label) table: reserved for \(table.vibe).")
                    }
                }
            }
        } label: {
            ZStack {
                // Rug
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.55, green: 0.22, blue: 0.2).opacity(0.45),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 78
                        )
                    )
                    .frame(width: 160, height: 120)

                // Chairs as little stools
                ForEach(0..<4, id: \.self) { i in
                    let angle = Double(i) * (.pi / 2) - .pi / 4
                    ZStack {
                        Capsule()
                            .fill(Color(red: 0.35, green: 0.22, blue: 0.14))
                            .frame(width: 22, height: 14)
                        Capsule()
                            .fill(Color(red: 0.55, green: 0.38, blue: 0.24))
                            .frame(width: 18, height: 8)
                            .offset(y: -3)
                    }
                    .offset(x: cos(angle) * 52, y: sin(angle) * 38)
                    .opacity(occupied && i < max(seatCount, 1) ? 1 : 0.45)
                    .scaleEffect(occupied && i < seatCount ? 1.05 : 0.95)
                }

                // Table
                ZStack {
                    Ellipse()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 100, height: 66)
                        .offset(y: 6)
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: occupied
                                    ? [Color(red: 0.62, green: 0.42, blue: 0.24), Color(red: 0.32, green: 0.18, blue: 0.1)]
                                    : [Color(red: 0.48, green: 0.32, blue: 0.18), Color(red: 0.26, green: 0.15, blue: 0.09)],
                                center: UnitPoint(x: 0.4, y: 0.35),
                                startRadius: 2,
                                endRadius: 55
                            )
                        )
                        .frame(width: 100, height: 64)
                        .overlay(
                            Ellipse()
                                .stroke(occupied ? CPTheme.accent.opacity(0.8) : Color.white.opacity(0.12), lineWidth: occupied ? 2.5 : 1)
                        )

                    // Mini laptop + cup when occupied
                    if occupied {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: 0.15, green: 0.16, blue: 0.18))
                                .frame(width: 18, height: 12)
                                .overlay(
                                    Rectangle()
                                        .fill(Color.cyan.opacity(0.4))
                                        .frame(width: 14, height: 8)
                                )
                            BeanCup(hue: 0.08)
                                .scaleEffect(clinking ? 1.25 : 1.0)
                        }
                        .offset(y: -4)
                    } else {
                        BeanCup(hue: 0.1)
                            .opacity(0.55)
                            .offset(y: -2)
                    }
                }
                .scaleEffect(clinking ? 1.06 : (occupied ? 1.03 : 1))
                .rotationEffect(.degrees(clinking ? -2 : 0))

                VStack(spacing: 2) {
                    Spacer().frame(height: 52)
                    Text(occupied ? partyNames(bound) : table.label.uppercased())
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(occupied ? CPTheme.text : CPTheme.muted)
                    Text(occupied ? "\(seatCount) Beans · \(table.vibe)" : table.vibe)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(CPTheme.accent.opacity(0.85))
                }
            }
            .frame(width: 140, height: 120)
        }
        .buttonStyle(.plain)
        .position(x: size.width * table.x, y: size.height * table.y)
        .help(occupied ? "Join the bit" : "Claim this table")
    }

    private func partyNames(_ thread: ChatThread?) -> String {
        guard let thread else { return "Table" }
        let names = thread.participantBeanIDs.compactMap { app.projects.bean(id: $0)?.name }
        if names.isEmpty { return "Table" }
        if names.count <= 2 { return names.joined(separator: " + ") }
        return "\(names[0]) + crew"
    }

    // MARK: - Chat cards on the floor

    private func chatCard(_ thread: ChatThread, size: CGSize) -> some View {
        let point = chatPoint(for: thread, size: size)
        let bean = app.projects.bean(id: thread.beanID)
        let busy = thread.isBusy
        let active = app.activeThreadID == thread.id

        return Button {
            app.selectThread(thread.id)
            pushTicker("Opened “\(thread.title)”.")
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.95, green: 0.92, blue: 0.85))
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    ChatMark(hue: bean?.accentHue ?? 0.08, busy: busy)
                        .frame(width: 18, height: 18)
                        .scaleEffect(busy && pulse ? 1.08 : 1.0)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(CPTheme.text)
                        .lineLimit(1)
                    Text(bean?.name ?? "loose chat")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(busy ? CPTheme.accent : CPTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: 110, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? CPTheme.composer : Color(red: 0.18, green: 0.13, blue: 0.10).opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(active ? CPTheme.accent.opacity(0.8) : Color.white.opacity(0.1), lineWidth: active ? 2 : 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            )
        }
        .buttonStyle(.plain)
        .position(point)
        .zIndex(busy ? 25 : 8)
        .help("Open chat")
        .contextMenu {
            Button("Open chat") { app.selectThread(thread.id) }
            if let bean, scopedBeans.contains(where: { $0.id != bean.id }) {
                let partners = scopedBeans.filter { $0.id != bean.id }
                if let partner = partners.first {
                    Button("Seat at table with \(partner.name)") {
                        Task {
                            _ = await app.createTableChat(
                                beanIDs: [bean.id, partner.id],
                                projectID: app.shopProjectID ?? thread.projectID
                            )
                            app.detailPane = .shop
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bean actors

    private func beanActor(_ bean: Bean, size: CGSize) -> some View {
        let state = presence.state(for: bean.id)
        let point = position(for: bean, state: state, size: size)
        let bubble = speakingBubble(for: bean, state: state)
        let selected = selectedForTable.contains(bean.id)
        let mood = BeanMood.from(state: state, selected: selected)
        let bob: CGFloat = {
            switch state {
            case .walking: return pulse ? -6 : 2
            case .speaking: return pulse ? -3 : 0
            case .idle: return pulse ? -2 : 1
            default: return 0
            }
        }()

        return Button {
            if NSEvent.modifierFlags.contains(.command) {
                if selectedForTable.contains(bean.id) {
                    selectedForTable.remove(bean.id)
                } else {
                    selectedForTable.insert(bean.id)
                    pushTicker("Tagged \(bean.name). They’re flattered.")
                }
            } else if case .seated(let tableID) = state {
                app.selectThread(tableID)
            } else if case .speaking(let tableID) = state {
                app.selectThread(tableID)
            } else {
                app.selectBean(bean.id)
                pushTicker("\(bean.name): “Yeah what’s up?”")
            }
        } label: {
            VStack(spacing: 4) {
                if let bubble {
                    SpeechBubble(text: bubble)
                        .transition(.scale.combined(with: .opacity))
                }

                ZStack {
                    Ellipse()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 40, height: 12)
                        .offset(y: 28)
                        .blur(radius: 2)

                    BeanBuddy(hue: bean.accentHue, mood: mood, scale: 1.15)
                        .offset(y: bob)
                        .rotationEffect(.degrees(state == .walking ? (pulse ? 6 : -6) : (selected ? -4 : 0)))

                    if selected {
                        Text("👆")
                            .font(.system(size: 12))
                            .offset(x: 22, y: -22)
                    }
                }

                VStack(spacing: 2) {
                    Text(bean.name)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(CPTheme.text)
                    Text(funStatus(bean, state))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(statusColor(state))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .position(point)
        .animation(.easeInOut(duration: 0.55), value: point.x)
        .animation(.easeInOut(duration: 0.55), value: point.y)
        .animation(.easeInOut(duration: 0.35), value: mood)
        .zIndex(mood == .rant ? 30 : 10)
        .help("⌘-click to tag · \(state.label)")
        .contextMenu { beanMenu(bean) }
    }

    private func funStatus(_ bean: Bean, _ state: BeanPresenceState) -> String {
        switch state {
        case .speaking: return "mid-rant"
        case .seated: return "sipping · \(bean.providerChip)"
        case .walking: return "on the move"
        case .handoff: return "passing notes"
        case .idle: return bean.providerChip
        }
    }

    private func statusColor(_ state: BeanPresenceState) -> Color {
        switch state {
        case .speaking: return CPTheme.accent
        case .seated: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .walking, .handoff: return Color.orange
        case .idle: return CPTheme.muted
        }
    }

    @ViewBuilder
    private func beanMenu(_ bean: Bean) -> some View {
        Button("Chat with \(bean.name)") { app.selectBean(bean.id) }
        Button(selectedForTable.contains(bean.id) ? "Untag" : "Tag for table") {
            if selectedForTable.contains(bean.id) { selectedForTable.remove(bean.id) }
            else { selectedForTable.insert(bean.id) }
        }
        if let active = app.activeThread, active.isTable,
           !active.participantBeanIDs.contains(bean.id) {
            Button("Drag to open table") {
                Task { await app.inviteBean(bean.id, to: active.id) }
                pushTicker("\(bean.name) got dragged into the bit.")
            }
        }
        let partners = scopedBeans.filter { $0.id != bean.id }
        if let partner = partners.first {
            Button("Table with \(partner.name)") {
                Task {
                    _ = await app.createTableChat(
                        beanIDs: [bean.id, partner.id],
                        projectID: app.shopProjectID ?? bean.projectID ?? partner.projectID
                    )
                    app.detailPane = .shop
                    pushTicker("\(bean.name) + \(partner.name): table acquired.")
                }
            }
        }
        Button("New chat with \(bean.name)") {
            Task {
                await app.newChat(projectID: app.shopProjectID ?? bean.projectID, beanID: bean.id)
                app.detailPane = .shop
                ensureChatOffsets()
                pushTicker("\(bean.name) got a fresh chat slip.")
            }
        }
    }

    // MARK: - Layout / ambient loop

    private func position(for bean: Bean, state: BeanPresenceState, size: CGSize) -> CGPoint {
        switch state {
        case .idle, .walking:
            let o = idleOffsets[bean.id] ?? CGPoint(x: 0.5, y: 0.55)
            // Mild wander when idle so the floor feels alive
            let w = Double(wanderTick + abs(bean.id.hashValue % 7))
            let jx = CGFloat(sin(w / 3.0)) * (state == .walking ? 0.03 : 0.012)
            let jy = CGFloat(cos(w / 4.0)) * (state == .walking ? 0.02 : 0.008)
            return CGPoint(
                x: size.width * min(0.9, max(0.1, o.x + jx)),
                y: size.height * min(0.88, max(0.30, o.y + jy))
            )
        case .seated(let tableID), .speaking(let tableID):
            return seatPoint(beanID: bean.id, tableID: tableID, size: size)
        case .handoff:
            let o = idleOffsets[bean.id] ?? CGPoint(x: 0.5, y: 0.5)
            return CGPoint(x: size.width * o.x, y: size.height * (o.y - 0.05))
        }
    }

    private func seatPoint(beanID: UUID, tableID: UUID, size: CGSize) -> CGPoint {
        let shopTable = shopTable(forThreadID: tableID)
        let seats: [UUID] = {
            if let thread = app.threads.first(where: { $0.id == tableID }) {
                return thread.participantBeanIDs
            }
            return [beanID]
        }()
        let idx = seats.firstIndex(of: beanID) ?? 0
        let angle = Double(idx) * (.pi / 2) - .pi / 4
        return CGPoint(
            x: size.width * (shopTable.x + cos(angle) * 0.09),
            y: size.height * (shopTable.y + sin(angle) * 0.08)
        )
    }

    private func shopTable(forThreadID id: UUID) -> ShopTable {
        let ordered = scopedTables
        if let i = ordered.firstIndex(where: { $0.id == id }) {
            return tables[i % tables.count]
        }
        return tables[abs(id.hashValue) % tables.count]
    }

    private func tableThread(for table: ShopTable) -> ChatThread? {
        let ordered = scopedTables
        guard table.id < ordered.count else { return nil }
        return ordered[table.id]
    }

    private func chatPoint(for thread: ChatThread, size: CGSize) -> CGPoint {
        // Prefer near the bean if we have one; else use assigned floor slot.
        if let beanID = thread.beanID,
           let bean = scopedBeans.first(where: { $0.id == beanID }),
           case .idle = presence.state(for: beanID) {
            let base = position(for: bean, state: .idle, size: size)
            return CGPoint(x: base.x + 48, y: base.y + 10)
        }
        let o = chatOffsets[thread.id] ?? CGPoint(x: 0.5, y: 0.6)
        return CGPoint(x: size.width * o.x, y: size.height * o.y)
    }

    private func ensureChatOffsets() {
        var next = chatOffsets
        let slots: [CGPoint] = [
            CGPoint(x: 0.18, y: 0.36),
            CGPoint(x: 0.50, y: 0.34),
            CGPoint(x: 0.82, y: 0.36),
            CGPoint(x: 0.16, y: 0.62),
            CGPoint(x: 0.50, y: 0.60),
            CGPoint(x: 0.84, y: 0.62),
            CGPoint(x: 0.30, y: 0.88),
            CGPoint(x: 0.70, y: 0.88),
        ]
        for (i, thread) in scopedChats.enumerated() {
            if next[thread.id] == nil {
                next[thread.id] = slots[i % slots.count]
            }
        }
        chatOffsets = next
    }

    private func speakingBubble(for bean: Bean, state: BeanPresenceState) -> String? {
        guard case .speaking(let tableID) = state else { return nil }
        guard let thread = app.threads.first(where: { $0.id == tableID }) else { return nil }
        let text = thread.messages.last(where: { $0.speakerBeanID == bean.id })?.text
            ?? thread.messages.last?.text
        guard let text, !text.isEmpty else { return "wait wait wait—" }
        if text.count <= 42 { return text }
        return String(text.prefix(39)) + "…"
    }

    private func ensureIdleOffsets() {
        var next = idleOffsets
        let waypoints: [CGPoint] = [
            CGPoint(x: 0.15, y: 0.34),
            CGPoint(x: 0.50, y: 0.32),
            CGPoint(x: 0.85, y: 0.35),
            CGPoint(x: 0.14, y: 0.58),
            CGPoint(x: 0.50, y: 0.58),
            CGPoint(x: 0.86, y: 0.58),
            CGPoint(x: 0.22, y: 0.90),
            CGPoint(x: 0.48, y: 0.91),
            CGPoint(x: 0.75, y: 0.89),
        ]
        for (i, bean) in scopedBeans.enumerated() {
            if next[bean.id] == nil {
                next[bean.id] = waypoints[i % waypoints.count]
            }
        }
        idleOffsets = next
    }

    private func startAmbientLoop() {
        Timer.scheduledTimer(withTimeInterval: 2.8, repeats: true) { _ in
            Task { @MainActor in
                wanderTick += 1
                if wanderTick % 4 == 0 {
                    specialIndex = (specialIndex + 1) % specials.count
                }
                if wanderTick % 5 == 0, !scopedBeans.isEmpty || !scopedChats.isEmpty {
                    let lines = [
                        "Someone refilled the tip jar with tokens.",
                        "Lo-fi BPM synced to the router fan.",
                        "A chat slip fluttered across the floor.",
                        "Steam π: still open. Still weird. Still good.",
                        "\(app.shopTitle): Wi‑Fi password is still ‘shipit’.",
                    ]
                    pushTicker(lines[wanderTick % lines.count])
                }
            }
        }
    }

    private func pushTicker(_ line: String) {
        withAnimation(.spring(response: 0.4)) {
            ticker.append(line)
            if ticker.count > 12 { ticker.removeFirst(ticker.count - 12) }
        }
    }

    private func pushPresenceTicker() {
        for bean in scopedBeans {
            switch presence.state(for: bean.id) {
            case .speaking:
                pushTicker("\(bean.name) grabbed the mic. Buckle up.")
            case .walking:
                pushTicker("\(bean.name) is pacing. Idea incoming.")
            case .handoff:
                pushTicker("\(bean.name) sliding a transcript across the table.")
            default:
                break
            }
        }
    }

    private func pickTranscriptJSONL() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.json, .plainText]
        if let jsonl = UTType(filenameExtension: "jsonl") { types.append(jsonl) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.message = "Drop a Cursor transcript into the shop"
        panel.prompt = "Gossip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let target = app.activeThreadID {
                await app.workWithTranscriptFile(at: url, into: target)
            } else if let cursor = app.projects.beans.first(where: { $0.name == "Cursor" }) {
                await app.newChat(projectID: cursor.projectID, beanID: cursor.id)
                if let target = app.activeThreadID {
                    await app.workWithTranscriptFile(at: url, into: target)
                }
            }
            pushTicker("Transcript landed. Beans are reading.")
            app.detailPane = .chat
        }
    }
}

// MARK: - Characters & chrome

private enum BeanMood: Equatable {
    case chill, walk, sip, rant, wave, tagged

    static func from(state: BeanPresenceState, selected: Bool) -> BeanMood {
        if selected { return .tagged }
        switch state {
        case .speaking: return .rant
        case .walking: return .walk
        case .seated: return .sip
        case .handoff: return .wave
        case .idle: return .chill
        }
    }
}

private struct BeanBuddy: View {
    let hue: Double
    var mood: BeanMood = .chill
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            // Body
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.55, brightness: 0.55),
                            Color(hue: hue, saturation: 0.7, brightness: 0.25),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34 * scale, height: 44 * scale)
                .rotationEffect(.degrees(-12))
                .shadow(color: Color(hue: hue, saturation: 0.6, brightness: 0.5).opacity(0.45), radius: mood == .rant ? 12 : 4)

            // Seam
            Capsule()
                .stroke(Color.black.opacity(0.35), lineWidth: 1.5)
                .frame(width: 2, height: 22 * scale)
                .rotationEffect(.degrees(-12))

            // Face
            VStack(spacing: 3 * scale) {
                HStack(spacing: 8 * scale) {
                    eye
                    eye
                }
                mouth
            }
            .offset(y: -2)

            // Cheeks
            HStack(spacing: 18 * scale) {
                Circle().fill(Color.pink.opacity(0.35)).frame(width: 5 * scale, height: 4 * scale)
                Circle().fill(Color.pink.opacity(0.35)).frame(width: 5 * scale, height: 4 * scale)
            }
            .offset(y: 6 * scale)

            // Little arms
            Capsule()
                .fill(Color(hue: hue, saturation: 0.5, brightness: 0.4))
                .frame(width: 10 * scale, height: 4 * scale)
                .rotationEffect(.degrees(mood == .wave || mood == .rant ? -40 : 20))
                .offset(x: -20 * scale, y: mood == .wave ? -6 : 4)
            Capsule()
                .fill(Color(hue: hue, saturation: 0.5, brightness: 0.4))
                .frame(width: 10 * scale, height: 4 * scale)
                .rotationEffect(.degrees(mood == .rant ? 50 : -15))
                .offset(x: 20 * scale, y: mood == .rant ? -8 : 4)
        }
        .frame(width: 56 * scale, height: 56 * scale)
    }

    private var eye: some View {
        Group {
            if mood == .sip {
                Capsule()
                    .fill(Color.white)
                    .frame(width: 6, height: 2)
            } else {
                ZStack {
                    Circle().fill(Color.white).frame(width: 7, height: 7)
                    Circle().fill(Color.black).frame(width: mood == .rant ? 4.5 : 3.2, height: mood == .rant ? 4.5 : 3.2)
                        .offset(x: mood == .walk ? 1 : 0, y: mood == .chill ? 0.5 : 0)
                }
            }
        }
    }

    private var mouth: some View {
        Group {
            switch mood {
            case .rant:
                Ellipse().fill(Color.black.opacity(0.75)).frame(width: 8, height: 6)
            case .wave, .tagged:
                Capsule().stroke(Color.black.opacity(0.7), lineWidth: 1.5).frame(width: 8, height: 4)
            case .sip:
                Capsule().fill(Color.black.opacity(0.5)).frame(width: 5, height: 2)
            case .walk:
                Capsule().fill(Color.black.opacity(0.6)).frame(width: 6, height: 2)
            case .chill:
                Capsule().stroke(Color.black.opacity(0.55), lineWidth: 1.2).frame(width: 7, height: 3)
            }
        }
    }
}

private struct BeanCup: View {
    let hue: Double
    var body: some View {
        ZStack {
            Capsule()
                .fill(Color(red: 0.92, green: 0.88, blue: 0.82))
                .frame(width: 14, height: 4)
                .offset(y: 6)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.9))
                .frame(width: 10, height: 9)
            Capsule()
                .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                .frame(width: 5, height: 5)
                .offset(x: 7, y: -1)
            Capsule()
                .fill(Color(hue: hue, saturation: 0.5, brightness: 0.35).opacity(0.8))
                .frame(width: 7, height: 3)
                .offset(y: -2)
        }
        .frame(width: 18, height: 16)
    }
}

private struct SpeechBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.15, green: 0.1, blue: 0.08))
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.96, green: 0.92, blue: 0.84))
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            )
            .frame(maxWidth: 150)
    }
}

private struct ShopSparkles: View {
    let active: Bool
    var body: some View {
        GeometryReader { geo in
            ForEach(0..<8, id: \.self) { i in
                Circle()
                    .fill(CPTheme.accent.opacity(active ? 0.35 : 0.1))
                    .frame(width: CGFloat(2 + i % 3), height: CGFloat(2 + i % 3))
                    .position(
                        x: geo.size.width * (0.1 + CGFloat(i) * 0.11),
                        y: geo.size.height * (0.25 + CGFloat((i * 3) % 5) * 0.12)
                            - (active ? 8 : 0)
                    )
                    .blur(radius: 0.5)
            }
        }
    }
}

private struct FunChip: View {
    let title: String
    let icon: String
    var hot: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FunChipLabel(title: title, icon: icon, hot: hot)
        }
        .buttonStyle(.plain)
    }
}

private struct FunChipLabel: View {
    let title: String
    let icon: String
    var hot: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(hot ? Color(red: 0.12, green: 0.08, blue: 0.06) : CPTheme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(hot ? CPTheme.accent : CPTheme.composer)
        )
        .overlay(
            Capsule().stroke(hot ? Color.clear : CPTheme.border, lineWidth: 1)
        )
    }
}

private struct ShopTable: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let label: String
    let vibe: String
}
