import CoreLocation
import SwiftUI

struct ContentView: View {

    let environment: HomecomingEnvironment

    /// 실제 위치를 쓸지, 가짜 이동을 재생할지.
    ///
    /// **화면에서 고르는 길은 없앴다.** 세그먼트 컨트롤이 맨 위 자리를 차지했는데
    /// 실제로 쓰는 것은 실데이터뿐이었다. 데모는 검증용으로 남겨 둔다 —
    /// `-autoStartHomecoming` 이 이 값을 `.demo` 로 돌린다.
    enum Mode: String, CaseIterable, Identifiable {
        case live = "실데이터"
        case demo = "데모"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .live
    @State private var showingHomePicker = false

    private var activity: HomecomingActivityManager { environment.activity }
    private var coordinator: HomecomingCoordinator { environment.coordinator }
    private var simulator: CommuteSimulator { environment.simulator }
    private var push: HomecomingPushRegistrar { environment.push }

    /// 탭. **`귀가` 가 기본이다** — 가족이 앱을 여는 이유가 그것뿐이다.
    ///
    /// 한 화면에 카드 아홉 개를 쌓아 두던 것을 나눴다. 세로로 길어서 아래쪽 카드는
    /// 스크롤해야 보였고, 가족은 맨 위 카드만 보면 되는데 조종석·진단까지 함께
    /// 내려가 있었다.
    enum Tab: Hashable {
        case journey, route, family, settings
    }

    @State private var tab: Tab = .journey

    var body: some View {
        TabView(selection: $tab) {
            page("귀가", subtitle: "귀가 과정을 가족에게 실시간으로") { journeyTab }
                .tabItem { Label("귀가", systemImage: "figure.walk.motion") }
                .tag(Tab.journey)

            page("경로", subtitle: "집과 귀가 경로") { routeTab }
                .tabItem { Label("경로", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(Tab.route)

            page("가족", subtitle: "내 귀가를 지켜보는 사람") { familyTab }
                .tabItem { Label("가족", systemImage: "person.2.fill") }
                .tag(Tab.family)

            page("설정") { settingsTab }
                .tabItem { Label("설정", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Color(red: 0.42, green: 0.85, blue: 0.62))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingHomePicker) {
            HomePickerView(
                initial: coordinator.home,
                currentLocation: coordinator.currentLocation
            ) { place in
                coordinator.setHome(place)
            }
        }
        .task {
            // 등록이 먼저다. 토큰 없이 나간 요청은 서버가 401 로 거절한다.
            await environment.registerIfNeeded()
            activity.reattach()
            environment.watching.start()
            coordinator.resumeIfNeeded()
            coordinator.requestAuthorization()
            coordinator.primeCurrentLocation()
            // **경로 목록을 여기서도 받는다.** 예전에는 `RouteCard` 의 `.task` 에서만
            // 받아서, 앱을 켜고 `귀가` 탭에 머무르면 목록이 비어 있었다 — 그러면
            // 고른 경로의 이름을 그릴 수 없다(`plannedJourneyCard`).
            await environment.routes.refresh()
            await runLaunchArguments()
        }
    }

    // MARK: - 탭

    /// 탭마다 같은 배경·여백·제목을 쓴다.
    ///
    /// 제목을 맨 위에 둔다 — 탭 막대의 글자는 작고 아래에 있어서, 스크롤하다
    /// 보면 지금 어느 탭인지 놓친다. `NavigationStack` 의 큰 제목을 쓰지 않는
    /// 이유는 이 화면이 자기 배경(어두운 그라디언트)을 직접 그리기 때문이다 —
    /// 내비게이션 바가 그 위에 자기 배경을 또 얹는다.
    private func page<Content: View>(
        _ title: String, subtitle: String? = nil, @ViewBuilder _ content: () -> Content
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.13), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    // **`alignment: .leading` 이 있어야 한다.** 없으면 VStack 이
                    // 자기 안에서 가운데를 잡아, 짧은 제목이 긴 부제 폭의 가운데로
                    // 밀린다 — 바깥을 왼쪽에 붙여도 제목만 안쪽으로 들어간다.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)

                    content()
                }
                .padding(24)
            }
        }
    }

    /// 지금 벌어지는 일. 가족이 보는 카드가 맨 위다.
    @ViewBuilder
    private var journeyTab: some View {
        watchingSection
        if hasWatching {
            Text("내 귀가")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        travelerStripCard
        runStatusCard
        plannedJourneyCard
        controls
        if let message = errorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 집과 경로. **집이 먼저다** — 경로의 마지막 구간 도착지가 집이라,
    /// 집이 없으면 경로를 만들 수 없다.
    @ViewBuilder
    private var routeTab: some View {
        homeCard
        if let home = coordinator.home {
            RouteCard(
                store: environment.routes,
                selectedID: Binding(
                    get: { coordinator.selectedRouteID },
                    set: { coordinator.selectedRouteID = $0 }
                ),
                plannedMinutes: Binding(
                    get: { coordinator.plannedMinutes },
                    set: { coordinator.plannedMinutes = $0 }
                ),
                home: home,
                here: coordinator.currentLocation?.coordinate,
                isRunning: activity.isRunning
            )
        }
    }

    @ViewBuilder
    private var familyTab: some View {
        PairingCard(store: environment.pairing, travelerName: coordinator.travelerName)
    }

    /// 이름·권한과 진단. 진단은 개발용이라 맨 아래다.
    @ViewBuilder
    private var settingsTab: some View {
        nameCard
        permissionCard
        // **안전귀가 모드는 이 토글이 유일한 스위치다.** 화면에서 빼 두었던 동안
        // `safetyMode` 는 `UserDefaults` 기본값 `false` 에 고정이었고, 켜는 길은
        // `-homecomingSafetyMode on` 런치 인자뿐이었다 — 즉 감시가 전부 꺼져 있었다.
        //
        // 이 토글이 켜는 것은 앱 안의 감시 셋이다: 지연·정지·무응답
        // (`SafetyWatch.anomaly`). **이탈은 여기 없다** — 경로 폴리라인이 필요해서
        // 서버가 판정하고(`estimateSource: "offRoute"`), 지도는 이 토글과 무관하게
        // 그 줄을 적는다.
        safetyCard
        diagnosticsCard
        pushCard
        hint
    }

    // MARK: - 가족이 보는 영역

    /// 지켜보는 사람이 있으면 **맨 위에** 온다.
    /// 가족이 앱을 여는 이유가 그것뿐이기 때문이다.
    @ViewBuilder
    private var watchingSection: some View {
        let entries = environment.watching.entries
        if !entries.isEmpty {
            VStack(spacing: 12) {
                ForEach(entries) { entry in
                    HomecomingJourneySection(
                        attributes: entry.attributes,
                        state: entry.state,
                        lastFixedAt: entry.receivedAt,
                        sessionID: entry.attributes.sessionID,
                        routes: environment.routeGeometry
                    )
                }
            }
        } else if !environment.pairing.watching.isEmpty {
            WatchingIdleCard(names: environment.pairing.watching.map(\.name))
        }
    }

    private var hasWatching: Bool {
        !environment.watching.entries.isEmpty || !environment.pairing.watching.isEmpty
    }

    // MARK: - 구성 요소

    /// 귀가자가 보는 카드. `watchingSection` 이 가족에게 그리는 것과 **같은
    /// `HomecomingJourneyCard` 다.** 배지·문구·카운트다운·노선도까지 글자 하나 안
    /// 틀리게 같아야 "가족에게 이렇게 보인다"는 확인이 참말이 된다 — 따로
    /// `RouteStripView` 만 떼어 그리면 배경·문구가 가족 화면과 갈라질 수 있다.
    ///
    /// `statusCard` 와 섞지 않는다. 그쪽은 조종석이다(가족에게 보이는 이름,
    /// 추정 출처, 관측 보정, 전송 상태). 진단값과 공유되는 그림은 성격이 다르다.
    /// 이번 귀가에서 **버스 도착 칩이 한 번이라도 떴는가.**
    ///
    /// 떴던 적이 있으면 값이 잠깐 비어도 계속 묻는다 — 안 그러면 스스로 못
    /// 되찾는다. 세션이 바뀌면 타이머가 다시 시작되므로 그때 꺼진다.
    @State private var sawBusArrival = false

    @ViewBuilder
    private var travelerStripCard: some View {
        if activity.isRunning,
           let attributes = activity.currentAttributes,
           let state = activity.currentState {
            // **가족 쪽과 같은 뷰다.** `routeShape != nil` 조건을 여기서 걸지
            // 않는다 — 걸면 경로 없는 귀가에서 귀가자 화면만 비어, 가족이 보는
            // 것과 달라진다. 카드는 경로가 없으면 진행 바를 그리고, 지도는
            // 좌표가 없으면 스스로 사라진다. 판단은 뷰가 한다.
            HomecomingJourneySection(
                attributes: attributes,
                state: state,
                lastFixedAt: coordinator.lastReportedAt,
                // **귀가자만 넘긴다.** 가족 카드(`watchingSection`)는 이 값을
                // 안 넘기므로 버튼이 안 그려진다.
                onRefreshBusArrival: { await coordinator.refreshBusArrival() },
                // 액티비티 고정값이 아니라 코디네이터의 값을 쓴다. 첫 출발에서는
                // 액티비티가 세션보다 먼저 떠서 고정값이 비어 있다.
                sessionID: coordinator.sessionID,
                routes: environment.routeGeometry
            )
            // **서 있는 동안에는 아무것도 갱신을 안 일으킨다.** 갱신의 유일한
            // 계기가 위치 보고인데 그건 150m 를 움직여야 나간다 — 정류장에서
            // 버스를 기다리는 그 시간이 정확히 그 상태다. 그래서 화면이 앞에
            // 있는 동안만 스스로 다시 묻는다.
            //
            // **한 번이라도 칩이 떴으면 계속 묻는다.** 예전에는 `busArrivalNo`
            // 가 있을 때만 돌았는데, 그러면 값이 잠깐 비는 순간 타이머가 스스로
            // 꺼진다 — 그리고 값을 되찾으려면 물어봐야 하는데 물지 않으니
            // 못 되찾는다.
            //
            // 2026-08-27 실귀가에서 그렇게 됐다. 18:34:09 에 자료가 값을 못
            // 줬고, 그 뒤 5분 동안 `/bus-arrival` 호출이 **한 번도 없었다.**
            // 사용자가 `↻` 를 눌러서야 돌아왔다. 버스를 기다리던 그 5분이다.
            //
            // 한 번도 안 뜬 구간(노선번호가 비었거나 승차 15분 전이 아니거나)
            // 에서는 여전히 안 묻는다. 그게 원래 막으려던 것이다.
            //
            // 30초는 서버 캐시와 같은 주기다. 더 자주 불러도 같은 값이 온다.
            .task(id: attributes.sessionID) {
                // **세션마다 처음부터 센다.** 지난 귀가에서 떴다는 이유로 이번
                // 귀가의 첫 구간부터 묻기 시작하면 안 된다.
                //
                // 화면에 들어올 때 이미 떠 있을 수도 있다(잠금화면에서 앱으로
                // 넘어온 경우). `onChange` 는 바뀔 때만 오므로 여기서 한 번 본다.
                sawBusArrival = state.busArrivalNo != nil
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    guard sawBusArrival else { continue }
                    await coordinator.refreshBusArrival()
                }
            }
            .onChange(of: state.busArrivalNo) { _, no in
                if no != nil { sawBusArrival = true }
            }
        }
    }

    /// 데모는 경로가 필요 없다 — 가짜 이동을 재생할 뿐이다.
    ///
    /// **경로가 없어도 시작할 수 있다.** 회식·모임에서 귀가하면 저장된 경로가 없는데,
    /// 그때도 가족은 봐야 한다. 대신 소요시간을 적어야 한다(`canStartWithoutRoute`) —
    /// 비워 두고 시작하면 가족 화면의 카운트다운이 근거를 잃는다.
    private var canStart: Bool {
        mode == .demo
            || (coordinator.home != nil
                && (coordinator.hasUsableRoute || coordinator.canStartWithoutRoute))
    }

    /// 막힌 이유. **어느 탭으로 가야 하는지 말한다** — 시작 버튼은 `귀가` 탭에
    /// 있고 전제(집·경로)는 `경로` 탭에 있어서, 이유만 적으면 어디를 눌러야
    /// 하는지 알 수 없다.
    private var startBlockedReason: String {
        if coordinator.home == nil { return "경로 탭에서 집 위치를 먼저 등록해 주세요." }
        return "경로 탭에서 경로를 고르거나, `경로 없이` 를 고른 뒤 예상 소요시간을 적어 주세요."
    }
    /// 지금 알림이 돌고 있는가. `귀가` 탭에 남는 유일한 조종석이다.
    ///
    /// 이름·진단은 `설정` 탭으로 옮겼다 — 한 카드에 성격이 다른 셋이 섞여
    /// 있었다(상태·설정값·진단값). 가족이 보는 화면에 가까워야 하는 탭에
    /// 개발용 숫자가 함께 내려가 있을 이유가 없다.
    /// 이번 귀가에 **무엇으로 가는가**. 대기 중일 때만 나온다.
    ///
    /// 경로는 `경로` 탭에서 고르는데 시작 버튼은 이 탭에 있다. 그래서 무엇으로
    /// 시작하는지 확인하려면 탭을 옮겨 갔다 와야 했다 — 매일 누르는 버튼 앞에서
    /// 그건 비싸다. 고른 것을 여기 적어 두면 누르기 전에 보인다.
    ///
    /// **귀가 중에는 그리지 않는다.** 위의 `travelerStripCard` 가 같은 것을 더
    /// 자세히(노선도·지도) 말하므로 두 번 적을 자리가 없다.
    @ViewBuilder
    private var plannedJourneyCard: some View {
        if mode == .live, !activity.isRunning {
            let route = coordinator.selectedRouteID.flatMap { id in
                environment.routes.routes.first { $0.id == id }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("이번 귀가")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))

                if let route {
                    Text("\(route.name) · \(route.durationText)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    if let stops = route.stops, !stops.isEmpty {
                        // 이름을 점에서 자른다. `출발역.은행앞` 처럼 붙는
                        // 이름이 실제로 있어서 한 줄에 안 들어간다 — 서버
                        // `short_place()` 와 같은 규칙이다.
                        Text(stops.map { $0.name.split(separator: ".").first.map(String.init)
                                          ?? $0.name }.joined(separator: " › "))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(3)
                    }
                } else if let minutes = coordinator.plannedMinutes, minutes > 0 {
                    Text("경로 없이 · \(minutes)분")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("지금 출발하면 \(Self.clockText(minutesFromNow: minutes)) 도착 예정")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("경로 없이")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("경로 탭에서 경로를 고르거나, 예상 소요시간을 적어 주세요.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
        }
    }

    /// `-homecomingDumpRoute` 가 찍는 모양. 서버가 `POST /route` 로 받는 것과 같다.
    ///
    /// `RouteLeg` 를 그대로 쓴다 — 그 타입이 이미 `Codable` 이고 키가 서버와 같아서,
    /// 여기서 다시 적으면 두 벌이 된다.
    private struct RouteWire: Decodable {
        struct Home: Decodable {
            let lat: Double
            let lon: Double
            let name: String
            let radius: Double
        }
        let name: String
        let home: Home
        let legs: [RouteLeg]
    }

    /// 지금부터 N분 뒤의 시각. `RouteCard` 의 같은 함수와 같은 형식으로 적는다 —
    /// 두 화면이 같은 값을 다르게 쓰면 어느 쪽이 맞는지 알 수 없다.
    private static func clockText(minutesFromNow minutes: Int) -> String {
        Date().addingTimeInterval(TimeInterval(minutes * 60))
            .formatted(.dateTime.hour().minute())
    }

    private var runStatusCard: some View {
        Card {
            HStack {
                Circle()
                    .fill(activity.isRunning ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 8, height: 8)
                Text(activity.isRunning ? "귀가 알림 진행 중" : "대기 중")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(progressText)
                    .font(.system(size: 13, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            }

            if !activity.activitiesEnabled {
                Note("설정 > 귀가 마중 에서 '실시간 활동'을 켜야 다이나믹 아일랜드에 표시됩니다.")
            }
        }
    }

    /// 가족에게 보이는 이름. 설정값이라 `설정` 탭이다.
    private var nameCard: some View {
        Card {
            HStack {
                Text("가족에게 보이는 이름")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 12)
                TextField("아빠", text: Binding(
                    get: { coordinator.travelerName },
                    set: { coordinator.travelerName = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .disabled(activity.isRunning)
            }
            if activity.isRunning {
                Note("귀가 중에는 바꿀 수 없습니다. 이름은 시작할 때 가족에게 갑니다.")
            }
        }
    }

    /// 진단값. **가족이 실제로 보는 값을 적는다** — 서버가 민 값이 있으면 그것이
    /// 참이고, 앱 자체 추정은 그게 없을 때만 쓴다(근거는 `sharedState` 주석).
    ///
    /// 개발·검증용이라 `설정` 탭 맨 위에 둔다. 귀가 중이 아니면 그릴 것이 없다.
    @ViewBuilder
    private var diagnosticsCard: some View {
        if mode == .live, let estimate = coordinator.lastEstimate {
            Card {
                Row("도착 예정", value: sharedState?.arrivalClockText
                    ?? estimate.expectedArrival.formatted(date: .omitted, time: .shortened))
                Row("이동 수단", value: "\((sharedState?.transport ?? estimate.transport).title)"
                    + " · 경로 \(routeLabel(estimate.routeMeters))")
                Row("추정 출처", value: sourceLabel(estimate.source))
                Row("관측 보정", value: paceLabel)
                Row("가족에게 전송", value: sessionLabel)
            }
        }
    }

    private var safetyCard: some View {
        Card {
            Toggle(isOn: Binding(
                get: { coordinator.safetyMode },
                set: { coordinator.safetyMode = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("안전귀가 모드")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(checkInIntervalLabel)마다 안심 확인 · 지연·정지 감시")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .tint(Color(red: 0.42, green: 0.85, blue: 0.62))
            .disabled(activity.isRunning)

            if let anomaly = coordinator.anomaly {
                HStack(spacing: 6) {
                    Image(systemName: anomaly.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(anomaly.title)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(anomaly.tint)
            }

            if coordinator.safetyMode && activity.isRunning {
                SmallButton("안심 확인") {
                    Task { await coordinator.checkIn() }
                }
            }
        }
    }

    /// 집. `경로` 탭이다 — 경로의 마지막 구간 도착지가 집이라 둘이 붙어 있어야 한다.
    private var homeCard: some View {
        Card {
            if let home = coordinator.home {
                Row("등록된 집", value: "\(home.name) · 반경 \(Int(home.arrivalRadius))m")
            } else {
                Note("집 위치가 없습니다. 집에서 아래 버튼을 눌러 등록해 주세요.")
            }

            HStack(spacing: 10) {
                SmallButton("지도에서 지정") {
                    showingHomePicker = true
                }

                // 비활성화하지 않는다. 위치가 아직 없으면 누르는 순간 위치를 요청한다.
                SmallButton(coordinator.isLocating ? "위치 확인 중…" : "현재 위치를 집으로") {
                    Task { await coordinator.setHomeToCurrentLocation() }
                }
                .disabled(coordinator.isLocating)
            }
        }
    }

    /// 위치 권한. 집과 성격이 달라 `설정` 탭으로 옮겼다 — 집은 "어디로 가는가"고
    /// 권한은 "이 앱이 무엇을 할 수 있는가"다.
    private var permissionCard: some View {
        Card {
            Row("위치 권한", value: authorizationLabel)
            Row("현재 위치", value: currentLocationLabel)

            if coordinator.authorization != .always {
                Note("'항상' 이어야 화면을 꺼도 가족에게 위치가 갑니다.")
                SmallButton("'항상' 권한 요청") {
                    coordinator.requestAuthorization()
                }
            }
        }
    }

    private var pushCard: some View {
        Card {
            Row("서버", value: environment.backendBaseURL?.host() ?? "미연결 (콘솔 출력)")
            Row("기기 토큰", value: shorten(push.deviceToken))
            Row("push-to-start", value: shorten(push.pushToStartToken))
            Row("액티비티 토큰", value: shorten(push.activityTokens.values.first))

            if push.pushToStartToken == nil {
                Note("push-to-start 토큰은 실기기에서만 발급됩니다. 이 토큰이 있어야 서버가 가족 기기에 알림을 띄울 수 있습니다.")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                switch mode {
                case .live: Task { await coordinator.start() }
                case .demo: simulator.start()
                }
            } label: {
                Label("귀가 시작", systemImage: "figure.walk.departure")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.36, green: 0.62, blue: 1.0))
            )
            .foregroundStyle(.white)
            .disabled(activity.isRunning || !canStart)
            .opacity(activity.isRunning || !canStart ? 0.4 : 1)

            // 왜 눌리지 않는지 말해 준다. 비활성 버튼만 두면 고장으로 읽힌다.
            if mode == .live, !canStart {
                Text(startBlockedReason)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(role: .destructive) {
                switch mode {
                case .live: Task { await coordinator.stop() }
                case .demo: simulator.stop()
                }
            } label: {
                Text("알림 끄기")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
            .foregroundStyle(.white.opacity(0.8))
            .disabled(!activity.isRunning)
            .opacity(activity.isRunning ? 1 : 0.4)
        }
    }

    /// **왼쪽 정렬로 통일한다.** 제목이 왼쪽인데 안내 문구만 가운데면 눈이
    /// 두 축을 오간다. 버튼 안 글자는 가운데가 맞다 — 그건 버튼의 관례다.
    private var hint: some View {
        Text("귀가 시작을 누른 뒤 홈으로 나가면 다이나믹 아일랜드에서 확인할 수 있어요.\n길게 누르면 확장 화면이 열립니다.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.35))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }

    // MARK: - 런치 인자 (시뮬레이터·QA 에서 손 안 대고 재생)

    /// ```
    /// -autoStartHomecoming                 데모 재생 시작
    /// -homecomingHome "37.5665,126.9780"   집 좌표 등록
    /// -autoLiveHomecoming                  실데이터 경로 시작
    /// -homecomingSetHomeHere               현재 위치를 집으로 등록 (버튼과 같은 경로)
    /// -homecomingSafetyMode on|off         안전귀가 모드 설정
    /// -homecomingCheckInSeconds 60         안심 확인 주기 (기본 15분, 검증용)
    /// -homecomingShowHomePicker            집 지정 화면을 바로 띄운다
    /// -homecomingPrintContract             API 명세용 페이로드를 로그로 찍는다
    /// -homecomingListActivities            지금 살아 있는 액티비티를 콘솔로 찍는다
    /// -homecomingToken <token>             인증 토큰 주입 (양쪽 역할 시험용)
    /// -homecomingResetIdentity             키체인 자격을 지우고 새 계정으로 등록
    /// -homecomingDumpRoute <id|이름>       경로를 서버가 받는 형태 그대로 콘솔에 찍는다
    /// -homecomingImportRoute <base64>      찍어 둔 경로를 **이 기기 계정으로** 저장한다
    /// -homecomingInvite                    초대 코드를 발급하고 콘솔에 찍는다
    /// -homecomingAcceptCode <code>         받은 코드로 연결한다
    /// -homecomingUnlink <accountId>        연결을 끊는다
    /// -homecomingListPairs                 연결 목록을 콘솔로 찍는다
    /// -homecomingStopSharing               공유를 중지한다 (중지 표시 확인용)
    /// -homecomingAudience traveler|watcher 어느 쪽 화면으로 그릴지 (검증용)
    /// ```
    private func runLaunchArguments() async {
        let arguments = ProcessInfo.processInfo.arguments

        if let index = arguments.firstIndex(of: "-homecomingHome"),
           index + 1 < arguments.count,
           let coordinate = Self.parseCoordinate(arguments[index + 1]) {
            coordinator.setHome(HomePlace(coordinate: coordinate))
        }

        if let index = arguments.firstIndex(of: "-homecomingSafetyMode"), index + 1 < arguments.count {
            coordinator.safetyMode = arguments[index + 1] == "on"
        }

        // 자격을 버리고 새 계정으로 등록한다. 재설치 없이 계정을 갈아 끼우는 길이다.
        if arguments.contains("-homecomingResetIdentity") {
            HomecomingCredentialStore.clear()
            environment.auth.set(nil)
            await environment.registerIfNeeded()
            print("[귀가마중] 자격 초기화 후 재등록")
        }

        // 저장된 경로 목록을 찍는다. 화면을 탭할 수단이 없을 때 id 를 알아내는 길이다.
        if arguments.contains("-homecomingListRoutes") {
            await environment.routes.refresh()
            for route in environment.routes.routes {
                print("[귀가마중] 경로 \(route.id) · \(route.name) · \(route.durationText)"
                      + " · 첫구간 [\(route.firstTransport?.rawValue ?? "-")] \"\(route.firstDetail ?? "-")\"")
            }
        }

        // **경로를 다른 계정으로 옮기는 길.**
        //
        // 경로는 서버에 있고 `GET /route/{id}` 는 소유자만 읽는다(`account_id = me`).
        // 계정은 키체인에 있고 `ThisDeviceOnly` 라 기기 사이를 넘지 않는다. 그래서
        // 기기를 바꾸거나 검증용 계정을 새로 만들면 **경로를 옮길 길이 없었다** —
        // 손으로 다시 만드는 것 말고는. 가족 권한으로 받을 수 있는 것은 좌표열과
        // 정류장뿐이라(`/session/{id}/route`) 구간별 소요시간이 빠지는데, 그 값은
        // 대중교통 앱 실측을 옮겨 적은 것이라 짐작으로 대신할 수 없다.
        //
        // 그래서 소유 기기가 자기 경로를 **서버가 받는 형태 그대로** 찍게 한다.
        // 찍은 것을 다른 계정의 `POST /route` 에 그대로 넣으면 값이 하나도 안 바뀐다.
        if let index = arguments.firstIndex(of: "-homecomingDumpRoute"), index + 1 < arguments.count {
            let wanted = arguments[index + 1]
            await environment.routes.refresh()
            let found = environment.routes.routes.first { $0.id == wanted || $0.name == wanted }
            if let found, let detail = await environment.routes.detail(of: found.id) {
                let payload: [String: Any] = [
                    "name": detail.name,
                    // `RouteDraft.totalSeconds` 와 같은 계산이다 — 마지막 구간이 끝나는 시각.
                    "totalSeconds": detail.legs.map { $0.startsAt + $0.seconds }.max() ?? 0,
                    "home": [
                        "lat": detail.home.latitude,
                        "lon": detail.home.longitude,
                        "name": detail.home.name,
                        "radius": detail.home.arrivalRadius,
                    ],
                    "legs": detail.legs.map(\.wire),
                ]
                if let data = try? JSONSerialization.data(
                    withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
                   let text = String(data: data, encoding: .utf8) {
                    // 한 줄로 찍는다. 여러 줄이면 콘솔에서 잘라 붙이기가 나쁘다.
                    print("[귀가마중] 경로 JSON \(detail.id) \(text)")
                }
            } else {
                print("[귀가마중] 경로를 못 찾았다: \(wanted)")
            }
        }

        // **찍어 둔 경로를 이 기기 계정에 넣는다.** `-homecomingDumpRoute` 의 짝이다.
        //
        // 기기를 바꾸면 계정이 새로 생기고(키체인이 `ThisDeviceOnly`) 경로가 하나도
        // 없다. 옛 기기에서 찍은 것을 여기 넣으면 **값이 하나도 안 바뀌고** 옮겨진다 —
        // 구간별 소요시간은 대중교통 앱 실측을 손으로 옮겨 적은 값이라, 좌표만 있는
        // 사본으로 대신할 수 없다(그건 시간을 짐작하게 된다).
        //
        // **base64 로 받는다.** 경로 JSON 이 6KB 남짓이고 한글 이름과 따옴표가 들어
        // 있어서, 그대로 넘기면 셸을 지나오는 동안 깨진다.
        if let index = arguments.firstIndex(of: "-homecomingImportRoute"), index + 1 < arguments.count {
            guard let data = Data(base64Encoded: arguments[index + 1]),
                  let wire = try? JSONDecoder().decode(RouteWire.self, from: data)
            else {
                print("[귀가마중] 경로를 읽지 못했다 — base64 이거나 형식이 다르다")
                return
            }
            let draft = RouteDraft(
                name: wire.name,
                home: HomePlace(name: wire.home.name,
                                coordinate: .init(latitude: wire.home.lat, longitude: wire.home.lon),
                                arrivalRadius: wire.home.radius),
                legs: wire.legs)
            if let id = await environment.routes.save(draft, replacing: nil) {
                print("[귀가마중] 경로 저장 \(id) · \(wire.name) · \(draft.totalSeconds / 60)분"
                      + " · 구간 \(wire.legs.count)개")
                coordinator.selectedRouteID = id
            } else {
                print("[귀가마중] 경로 저장 실패: \(environment.routes.lastError ?? "이유 없음")")
            }
        }

        // 이번 귀가에 쓸 경로를 고른다. 이름으로 골라도 되게 한 이유는
        // id 가 무작위 12자라 사람이 옮겨 적기 나쁘기 때문이다.
        if let index = arguments.firstIndex(of: "-homecomingRoute"), index + 1 < arguments.count {
            let wanted = arguments[index + 1]
            await environment.routes.refresh()
            let match = environment.routes.routes.first { $0.id == wanted || $0.name == wanted }
            coordinator.selectedRouteID = match?.id
            if let match {
                print("[귀가마중] 경로 선택 \(match.name) · \(match.durationText)")
            } else {
                print("[귀가마중] 경로를 못 찾았다: \(wanted)")
            }
        }

        if arguments.contains("-homecomingNoRoute") {
            coordinator.selectedRouteID = nil
            print("[귀가마중] 경로 해제 — 거리 기반 추정으로 돈다")
        }

        // 경로 만들기를 화면 없이 한 번 돌린다.
        //
        // 만들기 화면은 탭으로만 쓸 수 있는데 실기기·시뮬레이터에 탭을 넣을 수단이
        // 없다. 그래서 화면이 부르는 것과 **같은 코드**를 인자로도 부를 수 있게 둔다.
        // 확인하려는 것은 화면이 아니라 `RouteTracer` 가 실제로 쓸 만한 좌표열을
        // 만들어 서버가 받아들이는가다.
        if arguments.contains("-homecomingMakeRoute") {
            await RouteSample.make(environment: environment, coordinator: coordinator)
        }

        // 장소 검색이 실제로 한국 역·정류장 이름을 찾는지 본다.
        //
        // 경로 만들기 전체가 이것에 달려 있다. 검색이 "서강대역" 을 못 찾으면 폼에서
        // 좌표를 채울 방법이 없고, 폼은 무용지물이 된다. 맥에서 `CLGeocoder` 로
        // 시험했을 때 한국 역 이름이 통째로 실패했던 적이 있어(kCLErrorDomain 8)
        // 짐작으로 넘기지 않는다.
        if arguments.contains("-homecomingSearchPlaces") {
            await RouteSample.probeSearch()
        }

        if let index = arguments.firstIndex(of: "-homecomingCheckInSeconds"), index + 1 < arguments.count,
           let seconds = TimeInterval(arguments[index + 1]) {
            coordinator.checkInInterval = seconds
        }

        if let index = arguments.firstIndex(of: "-homecomingAudience"), index + 1 < arguments.count,
           let audience = HomecomingAttributes.Audience(rawValue: arguments[index + 1]) {
            activity.audience = audience
        }

        if arguments.contains("-homecomingPrintContract") {
            ContractDump.run()
        }

        if arguments.contains("-homecomingListActivities") {
            ContractDump.listActivities()
        }

        if arguments.contains("-homecomingInvite") {
            await environment.pairing.createInvite(travelerName: coordinator.travelerName)
            if let invite = environment.pairing.invite {
                print("[귀가마중] 초대 코드: \(invite.code)")
            } else {
                print("[귀가마중] 초대 코드 발급 실패: \(environment.pairing.lastError ?? "-")")
            }
        }

        if let index = arguments.firstIndex(of: "-homecomingAcceptCode"), index + 1 < arguments.count {
            let ok = await environment.pairing.accept(code: arguments[index + 1])
            print("[귀가마중] 연결 \(ok ? "성공" : "실패: \(environment.pairing.lastError ?? "-")")")
        }

        if let index = arguments.firstIndex(of: "-homecomingUnlink"), index + 1 < arguments.count {
            await environment.pairing.unlink(
                PairMember(accountID: arguments[index + 1], name: "-")
            )
            print("[귀가마중] 해제 요청 완료")
        }

        // 귀가 시작을 탭 없이 누른다. 시작 순간의 도착예정이 어디서 나왔는지가
        // 눈으로 확인해야 하는 값이라(경로를 골랐으면 실측, 아니면 MapKit),
        // 중지에만 있던 짝을 맞춘다.
        if arguments.contains("-homecomingStartSharing") {
            // 앞 실행의 액티비티가 남아 있으면 `start()` 가 "이미 진행 중" 으로
            // 조용히 빠져나간다. 시험은 늘 같은 자리에서 시작해야 한다.
            if activity.isRunning { await coordinator.stop() }
            await coordinator.start()
            if let estimate = coordinator.lastEstimate {
                print("[귀가마중] 시작 · 도착예정 \(estimate.remainingMinutesFromNow)분 "
                      + "· 출처 \(estimate.source.rawValue) "
                      + "· 경로 \(coordinator.selectedRouteID ?? "없음")")
            } else {
                print("[귀가마중] 시작 실패 · \(coordinator.lastError ?? "이유 없음")")
            }
        }

        if arguments.contains("-homecomingStopSharing") {
            await ContractDump.stopSharing()
        }

        if arguments.contains("-homecomingListPairs") {
            await environment.pairing.refresh()
            print("[귀가마중] 나를 보는 가족: \(environment.pairing.watchers.map(\.name).joined(separator: ", "))")
            print("[귀가마중] 내가 보는 사람: \(environment.pairing.watching.map(\.name).joined(separator: ", "))")
        }

        if arguments.contains("-homecomingShowHomePicker") {
            // 첫 렌더가 끝나기 전에 시트 상태를 올리면 그대로 삼켜진다.
            try? await Task.sleep(for: .milliseconds(400))
            showingHomePicker = true
        }

        if arguments.contains("-homecomingSetHomeHere") {
            await coordinator.setHomeToCurrentLocation()
        }

        if arguments.contains("-autoStartHomecoming") {
            mode = .demo
            simulator.start()
        } else if arguments.contains("-autoLiveHomecoming") {
            mode = .live
            await coordinator.start()
        }
    }

    private static func parseCoordinate(_ raw: String) -> CLLocationCoordinate2D? {
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    // MARK: - 표시값

    /// 가족이 지금 보고 있는 값. 서버가 민 것이다.
    ///
    /// **조종석은 여기를 먼저 봐야 한다.** 이 화면의 목적은 "가족에게 이렇게 보인다"
    /// 를 확인하는 것인데, 앱 자체 추정을 적으면 확인이 거짓말이 된다. 2026-08-18
    /// 실주행 18:55 한 화면에 남은거리가 셋(카드 2.1km · 조종석 8.3km · 경로 총길이
    /// 27.2km), 도착시각이 둘(카드 18:44 · 조종석 18:52) 있었다.
    ///
    /// nil 이면 아직 액티비티가 없거나 서버가 한 번도 못 밀었다는 뜻이다. 그때는
    /// 앱 추정을 적는 게 맞다 — 빈칸보다 낫고, 그 상황에서는 그게 유일하게 아는 값이다.
    private var sharedState: HomecomingAttributes.ContentState? {
        mode == .live ? activity.currentState : nil
    }

    private var progressText: String {
        switch mode {
        case .demo:
            return simulator.progressText
        case .live:
            if let shared = sharedState { return "\(shared.remainingDistanceText) 남음" }
            guard let meters = coordinator.remainingMeters else { return "" }
            if meters < 1_000 { return "\(meters)m 남음" }
            return String(format: "%.1fkm 남음", Double(meters) / 1_000)
        }
    }

    private var checkInIntervalLabel: String {
        let seconds = Int(coordinator.checkInInterval)
        return seconds < 60 ? "\(seconds)초" : "\(seconds / 60)분"
    }

    private var currentLocationLabel: String {
        if let address = coordinator.currentAddress, !address.isEmpty { return address }
        if coordinator.currentLocation != nil {
            return coordinator.isResolvingAddress ? "주소 확인 중…" : "주소를 찾지 못함"
        }
        return coordinator.isLocating ? "위치 확인 중…" : "없음"
    }

    /// 실제 접근 속도와 그 값을 얼마나 반영했는지.
    private var paceLabel: String {
        guard let kph = coordinator.observedSpeedKPH else { return "관측 중…" }
        return String(format: "%.0fkm/h · %.0f%% 반영", kph, coordinator.paceWeight * 100)
    }

    /// 서버가 이 귀가를 알고 있는지. 이게 없으면 가족은 아무것도 못 본다.
    private var sessionLabel: String {
        guard let id = coordinator.sessionID else {
            return environment.backendBaseURL == nil ? "서버 미연결" : "연결 안 됨"
        }
        guard let at = coordinator.lastReportedAt else { return id }
        let seconds = Int(Date().timeIntervalSince(at))
        return "\(id) · \(seconds)초 전"
    }

    private func routeLabel(_ meters: Int) -> String {
        meters < 1_000 ? "\(meters)m" : String(format: "%.1fkm", Double(meters) / 1_000)
    }

    private var authorizationLabel: String {
        switch coordinator.authorization {
        case .notDetermined: return "미결정"
        case .denied:        return "거부됨"
        case .whenInUse:     return "사용 중에만"
        case .always:        return "항상"
        }
    }

    private var errorMessage: String? {
        mode == .live
            ? (coordinator.lastError ?? coordinator.locationError ?? push.lastError)
            : simulator.lastError
    }

    /// **서버가 밝힌 방식이 있으면 그것이 참이다.**
    ///
    /// 앱은 자기가 저장된 경로로 시작한 것만 알고, 서버가 도중에 경로를 벗어나
    /// 직선거리 추정으로 되돌아간 것은 모른다. 2026-08-18 실주행에서 서버는 18:13 에
    /// 이탈했는데 이 행은 끝까지 `저장된 경로 (실측)` 을 적고 있었다. 그걸 믿고
    /// "경로 기반이니 남은거리는 경로 거리다" 로 읽으면 진단이 통째로 어긋난다.
    private func sourceLabel(_ source: ETAEstimate.Source) -> String {
        switch sharedState?.estimateSource {
        case "route":    return "저장된 경로 (실측) · 서버"
        case "offRoute": return "직선거리 · 서버 (경로 벗어남)"
        case "distance": return "직선거리 · 서버 (경로 없음)"
        default:         break
        }
        switch source {
        case .savedRoute:     return "저장된 경로 (실측)"
        case .traveler:       return "귀가자 입력"
        case .transit:        return "대중교통 (서버)"
        case .mapKit:         return "MapKit"
        case .deadReckoning:  return "기기 내 추측"
        }
    }

    private func shorten(_ token: String?) -> String {
        guard let token else { return "—" }
        return token.count > 12 ? "\(token.prefix(8))…\(token.suffix(4))" : token
    }
}

// MARK: - 작은 부품

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
    }
}

private struct Row: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.orange.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmallButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.1))
                )
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
