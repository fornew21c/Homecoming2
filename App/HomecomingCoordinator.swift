import CoreLocation
import Foundation
import Observation

/// 실데이터 파이프라인. 위치 → 남은 거리 → ETA → Live Activity.
///
/// 데모의 `CommuteSimulator` 가 앉아 있던 자리를 그대로 대체한다.
/// `HomecomingActivityManager` 의 start / update / finish 호출 모양은 똑같다.
@MainActor
@Observable
final class HomecomingCoordinator {

    // MARK: 의존

    private let activity: HomecomingActivityManager
    private let tracker: HomecomingLocationTracker
    private let eta: ETAProviding
    private let sessions: SessionReporting

    // MARK: 상태

    private(set) var home: HomePlace?
    private(set) var lastEstimate: ETAEstimate?
    private(set) var remainingMeters: Int?
    private(set) var lastError: String?

    /// 가족 화면에 뜨는 내 호칭. 남이 보는 값이므로 하드코딩해선 안 된다.
    var travelerName: String = UserDefaults.standard.string(forKey: "homecoming.travelerName") ?? "아빠" {
        didSet { UserDefaults.standard.set(travelerName, forKey: "homecoming.travelerName") }
    }

    var isRunning: Bool { activity.isRunning }
    var authorization: HomecomingLocationTracker.Authorization { tracker.authorization }
    var currentLocation: CLLocation? { tracker.lastLocation }

    // MARK: 갱신 억제

    /// 마지막으로 ETA 를 새로 물어본 시각과 그때의 위치.
    private var lastETARefresh: Date?
    private var lastETAOrigin: CLLocation?
    private var refreshTask: Task<Void, Never>?
    private var finishing = false

    // MARK: 안전귀가

    /// 안전귀가 모드. 켜면 안심 확인 마감이 붙고 이상 상황을 감시한다.
    var safetyMode: Bool {
        didSet { UserDefaults.standard.set(safetyMode, forKey: Self.safetyModeKey) }
    }

    /// 안심 확인 주기.
    var checkInInterval: TimeInterval = HomecomingCheckIn.defaultInterval

    // MARK: 저장된 경로

    /// 이번 귀가에 쓸 저장 경로. nil 이면 거리 기반 추정으로 돈다.
    ///
    /// 고르면 도착예정이 그 경로의 실측 소요시간에서 나온다. 지하철처럼 위치가
    /// 부정확한 구간에서도 흔들리지 않는다 — 애초에 위치로 나누는 게 아니다.
    var selectedRouteID: String? {
        didSet { UserDefaults.standard.set(selectedRouteID, forKey: Self.selectedRouteKey) }
    }

    static let selectedRouteKey = "homecoming.selectedRouteId"

    /// 고른 경로를 찾아 준다. 환경이 꽂아 준다.
    ///
    /// 이게 없으면 **시작 순간의 카드가 경로를 무시한다.** 앱이 MapKit 으로 계산해
    /// 띄우고, 서버가 첫 위치 보고를 받아 푸시를 쏴야 그제서야 실측값으로 바뀐다.
    /// 실제로 버스-지하철-버스 84분 경로에서 카드가 **20분으로 떴다가 84분으로
    /// 튀었다** — 자동차로 자유로를 타면 20분이니 MapKit 은 틀리지 않았다.
    /// 틀린 건 그 사람이 차를 타지 않는다는 것이다.
    ///
    /// 경로의 소요시간은 앱도 알고 있다. 서버를 기다릴 이유가 없다.
    var selectedRoute: (@MainActor (String) -> HomecomingRoute?)?

    private(set) var anomaly: HomecomingAttributes.Anomaly?
    private var watch = SafetyWatch()

    // MARK: 관측 보정

    /// 실제 접근 속도. 외부 추정을 보정한다.
    private var pace = TravelPace()

    /// 이미 내보낸 도착 예정. 매 갱신마다 몇 초씩 흔들리면 카운트다운이 튄다.
    private var publishedArrival: Date?
    private let arrivalJitterThreshold: TimeInterval = 20

    var observedSpeedKPH: Double? { pace.observedKilometersPerHour() }
    var paceWeight: Double { pace.weight() }

    // MARK: 서버 세션

    /// 서버가 이 귀가에 붙인 ID. 없으면 서버가 이 귀가를 모른다 = 가족도 못 본다.
    ///
    /// 앱이 메모리에서 내려갔다 돌아와도 같은 세션을 이어가야 한다.
    /// 잃어버리면 위치 보고가 끊기고, 가족 화면은 마지막 값에서 그대로 멈춘다.
    private(set) var sessionID: String? {
        didSet {
            if let sessionID {
                UserDefaults.standard.set(sessionID, forKey: Self.sessionIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.sessionIDKey)
            }
        }
    }

    private static let sessionIDKey = "homecoming.sessionId"

    /// 마지막으로 위치를 서버에 **보고한** 시각(GPS 픽스 시각이 아니다).
    ///
    /// 노선도의 "N분 전 확인" 문구는 이 값을 쓴다. 얼핏 다른 뜻처럼 보이지만
    /// (로컬 GPS 는 이보다 더 최근일 수 있다), 이 카드가 보여 주려는 건 "내가
    /// 지금 어디 있는가"가 아니라 "가족에게 지금 이렇게 보인다"는 확인이다.
    /// 세션이 끊기거나 보고가 막히면 GPS 는 계속 갱신돼도 가족 화면은 멈춰
    /// 있다 — 그 멈춤을 그대로 보여줘야 한다. `statusCard` 의 "가족에게 전송"
    /// 행(`sessionLabel`)도 같은 값으로 같은 뜻을 잰다.
    private(set) var lastReportedAt: Date?

    /// 위치를 매 픽스마다 올리면 서버도 배터리도 못 버틴다.
    /// 집 근처에서는 촘촘하게 — 마지막 몇 분이 가족에게 가장 중요한 구간이다.
    private var lastReportOrigin: CLLocation?
    private let reportMinInterval: TimeInterval = 15
    private let reportMinDisplacement: CLLocationDistance = 100
    private let reportMinIntervalNearHome: TimeInterval = 8
    private let reportMinDisplacementNearHome: CLLocationDistance = 40

    /// 현재 위치의 주소. 좌표만 보여 주면 그게 어딘지 알 수 없다.
    private let addresses = AddressResolver()
    var currentAddress: String? { addresses.address }
    var isResolvingAddress: Bool { addresses.isResolving }

    /// 아무도 움직이지 않아도 이상 판정은 돌아야 한다.
    /// '멈춰 있음'과 '무응답'은 정의상 위치 갱신이 없을 때 성립하기 때문이다.
    private var watchTask: Task<Void, Never>?
    private static let watchInterval: Duration = .seconds(30)

    private var heartbeatTask: Task<Void, Never>?
    /// 안 움직여도 이 간격마다 한 번은 보고한다.
    ///
    /// 노선도의 "N분 전 확인" 문턱(3분)보다 짧아야 뜻이 있다. 2분이면 왕복 지연을
    /// 감안해도 문턱에 안 닿는다. 근거는 `startHeartbeat()` 주석에 있다.
    private static let heartbeatSeconds: TimeInterval = 120

    /// heartbeat 이 "방금 보고했다" 로 보고 거를 기준. **자는 시간과 같은 값을
    /// 쓰면 안 된다.**
    ///
    /// 120초 자고 일어나 "마지막 보고가 120초보다 오래됐나" 를 물으면 119.x초로
    /// 읽힌다 — 재는 시작점(보고가 **끝난** 시각)이 타이머 시작보다 뒤라서다.
    /// 그래서 첫 발화가 매번 걸러지고 **실효 간격이 4분**이 된다.
    ///
    /// 2026-08-27 에 실제로 그랬다. 12:49:07 시작, 12:51 발화가 건너뛰어지고
    /// 12:53:08 에야 첫 제자리 보고가 나갔다. 그 4분 동안 버스 도착 칩이 비어
    /// 있었고, 위 주석이 요구한 "3분 문턱보다 짧게" 도 깨져 있었다.
    private static let heartbeatSkipSeconds: TimeInterval = heartbeatSeconds / 2
    private static let safetyModeKey = "homecoming.safetyMode"
    private static let plannedMinutesKey = "homecoming.plannedMinutes"

    /// ETA 를 다시 물어보는 최소 간격(초). 위치 픽스마다 부르면 서버도 배터리도 못 버틴다.
    private let etaMinInterval: TimeInterval = 45

    /// 이만큼 움직였으면 간격을 안 채웠어도 다시 물어본다.
    private let etaMinDisplacement: CLLocationDistance = 400

    /// 집 근처에서는 더 자주. 마지막 몇 분이 가족에게 가장 중요한 구간이다.
    private let nearHomeRadius: CLLocationDistance = 1_000
    private let etaMinIntervalNearHome: TimeInterval = 20
    private let etaMinDisplacementNearHome: CLLocationDistance = 120

    // MARK: - 생성

    init(
        activity: HomecomingActivityManager,
        tracker: HomecomingLocationTracker,
        eta: ETAProviding,
        sessions: SessionReporting
    ) {
        self.activity = activity
        self.tracker = tracker
        self.eta = eta
        self.sessions = sessions
        self.home = HomePlace.load()
        self.safetyMode = UserDefaults.standard.bool(forKey: Self.safetyModeKey)
        self.selectedRouteID = UserDefaults.standard.string(forKey: Self.selectedRouteKey)

        tracker.onLocation = { [weak self] location in
            self?.addresses.resolve(location)
            self?.handle(location)
        }
        tracker.onArrivedHome = { [weak self] in
            self?.handleArrival(reason: "지오펜스")
        }
    }

    /// 기본 조합: 서버 대중교통 추정 → MapKit → 기기 내 추측.
    /// `backendBaseURL` 이 없으면 대중교통 단계를 건너뛴다.
    static func makeDefaultETAProvider(backendBaseURL: URL?) -> ETAProviding {
        var providers: [ETAProviding] = []
        if let backendBaseURL {
            providers.append(TransitETAProvider(baseURL: backendBaseURL))
        }
        providers.append(MapKitETAProvider())
        providers.append(DeadReckoningETAProvider())
        return FallbackETAProvider(providers)
    }

    // MARK: - 집 등록

    func requestAuthorization() {
        tracker.requestAuthorization()
    }

    /// 집을 등록할 수 있도록 현재 위치를 한 번 받아 둔다.
    func primeCurrentLocation() {
        tracker.requestOneShotLocation()
    }

    /// 위치를 받는 중인지. 버튼 라벨에 쓴다.
    var isLocating: Bool { tracker.isLocating }

    /// 위치 계층에서 올라온 오류. 코디네이터 자신의 오류와 함께 화면에 보여 준다.
    var locationError: String? { tracker.lastError }

    /// 지금 있는 곳을 집으로 등록한다.
    ///
    /// 위치가 없으면 실패로 끝내지 않고 그 자리에서 요청해 기다린다.
    /// 사용자 입장에서 눌렀는데 아무 일도 안 일어나는 것이 가장 나쁘다.
    @discardableResult
    func setHomeToCurrentLocation(name: String = "집") async -> Bool {
        guard let location = await awaitLocation(timeout: 10) else {
            lastError = "위치를 아직 못 잡았습니다. 잠시 뒤 다시 눌러 주세요."
            return false
        }
        let place = HomePlace(name: name, coordinate: location.coordinate)
        place.save()
        home = place
        lastError = nil
        HomecomingLog.location.notice("집 등록 완료 반경=\(Int(place.arrivalRadius))m")
        return true
    }

    func setHome(_ place: HomePlace) {
        place.save()
        home = place
    }

    // MARK: - 시작 / 종료

    /// 고른 경로가 실제로 쓸 만한가.
    ///
    /// 목록에 없거나 소요시간이 0 이면 고른 것으로 치지 않는다 — 그 상태로 시작하면
    /// `startingEstimate()` 가 폴백으로 떨어진다.
    /// 경로 없이 귀가할 때 **귀가자가 적은** 예상 소요시간(분).
    ///
    /// 회식·모임에서 귀가하면 저장된 경로가 없다. 그래도 가족은 봐야 하고,
    /// 도착 시각도 알아야 한다. 그 시각을 계산하지 않고 **사람에게 묻는다** —
    /// 저장된 경로에 실측 시간을 적어 두는 것과 같은 생각이다.
    ///
    /// 다음 귀가에서도 대개 비슷하므로 기억해 둔다.
    var plannedMinutes: Int? = {
        let saved = UserDefaults.standard.integer(forKey: "homecoming.plannedMinutes")
        return saved > 0 ? saved : nil
    }() {
        didSet {
            if let plannedMinutes {
                UserDefaults.standard.set(plannedMinutes, forKey: Self.plannedMinutesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.plannedMinutesKey)
            }
        }
    }

    /// 경로 없이 시작할 수 있는가. 적어 둔 시간이 있어야 한다.
    ///
    /// **비워 두고 시작하게 하지 않는다.** 시간을 모르면 가족 화면의 카운트다운이
    /// 근거를 잃고, 안전귀가의 지연 감지도 기준이 없어진다.
    var canStartWithoutRoute: Bool { (plannedMinutes ?? 0) > 0 }

    var hasUsableRoute: Bool {
        guard let id = selectedRouteID, let route = selectedRoute?(id) else { return false }
        return route.totalSeconds > 0
    }

    func start() async {
        guard !isRunning else {
            HomecomingLog.activity.notice("시작 생략: 이미 진행 중")
            return
        }
        guard let home else {
            lastError = "먼저 집 위치를 등록해 주세요."
            HomecomingLog.activity.error("시작 실패: 집 미등록")
            return
        }
        // **경로가 없으면 귀가자가 적은 시간이 있어야 한다.**
        //
        // 예전에는 경로 없이 시작하는 것을 아예 막았다. 이유는 도착예정이었다 —
        // 경로가 없으면 MapKit 자동차 경로에서 나오고, 82분짜리 길이 19분으로
        // 뜬다. 가족은 그 시각에 맞춰 마중을 나간다. 틀린 시각을 믿게 만드는 것은
        // 아무것도 안 알리는 것보다 나쁘다.
        //
        // 그런데 **귀가는 직장에서만 시작하지 않는다.** 회식 자리에서도, 친구
        // 모임에서도 집에 간다. 그때 저장된 경로는 없고, 막아 두면 가족은 아무것도
        // 못 본다 — 정작 늦은 밤에 지켜볼 이유가 가장 큰 때다.
        //
        // 그래서 막는 대신 **시간을 사람에게 묻는다.** 계산하지 않으니 틀린 시각을
        // 믿게 만들 일이 없고, "한 시간쯤" 은 회식 자리에서도 아는 값이다.
        // 지도는 경로가 없어도 그려지므로 "어디쯤" 도 답할 수 있다.
        guard hasUsableRoute || canStartWithoutRoute else {
            lastError = "경로를 고르거나, 예상 소요시간을 적어 주세요."
            HomecomingLog.activity.error("시작 실패: 경로도 예상시간도 없음")
            return
        }
        guard tracker.authorization == .whenInUse || tracker.authorization == .always else {
            lastError = "위치 권한이 필요합니다."
            HomecomingLog.activity.error("시작 실패: 위치 권한 \(String(describing: self.tracker.authorization), privacy: .public)")
            tracker.requestAuthorization()
            return
        }

        lastError = nil
        finishing = false
        anomaly = nil
        watch.reset()
        pace.reset()
        publishedArrival = nil

        // 실데이터 경로는 서버 갱신을 받는다. 데모가 꺼 뒀을 수 있으니 되돌린다.
        activity.pushType = .token

        // 액티비티를 띄우려면 출발 시점의 ETA 가 있어야 한다.
        // 위치를 아직 못 잡았으면 잠깐 기다린다 — 여기서 실패하면 시작 자체가 없다.
        guard let origin = await waitForLocation(timeout: 8) else {
            lastError = "위치를 아직 못 잡았습니다. 잠시 뒤 다시 눌러 주세요."
            HomecomingLog.activity.error("시작 실패: 위치 픽스 없음")
            return
        }

        let estimate = await startingEstimate(from: origin, to: home)
        lastEstimate = estimate
        lastETARefresh = Date()
        lastETAOrigin = origin
        remainingMeters = estimate.routeMeters
        HomecomingLog.eta.notice(
            """
            ETA \(estimate.source.rawValue, privacy: .public) \
            수단=\(estimate.transport.rawValue, privacy: .public) \
            경로=\(estimate.routeMeters)m \
            직선=\(Int(origin.distance(from: home.location)))m \
            \(estimate.remainingMinutesFromNow)분
            """
        )

        do {
            try activity.start(
                travelerName: travelerName,
                destinationName: home.name,
                transport: estimate.transport,
                totalMeters: estimate.routeMeters,
                expectedArrival: estimate.expectedArrival,
                detail: estimate.detail,
                routeShape: estimate.routeShape,
                checkInDeadline: safetyMode ? Date().addingTimeInterval(checkInInterval) : nil,
                // 이미 아는 세션이면 실어 보낸다. 첫 출발에서는 nil 이다 —
                // 세션은 아래 `openSession` 에서 열리고, 액티비티는 그보다 먼저
                // 떠야 한다(서버 응답을 기다리면 버튼을 누른 뒤 화면이 늦는다).
                // 앱이 귀가 중에 재시작되면 저장된 세션을 물려받으므로 그때 채워진다.
                sessionID: sessionID,
                // 출발 시점의 자리와 집. 첫 위치 보고가 서버에 닿기 전에도 가족
                // 지도가 빈칸이 아니다.
                coordinate: tracker.lastLocation?.coordinate,
                home: home.coordinate,
                homeRadius: Int(home.arrivalRadius)
            )
        } catch {
            lastError = error.localizedDescription
            HomecomingLog.activity.error("액티비티 시작 실패: \(error.localizedDescription, privacy: .public)")
            return
        }

        tracker.startTracking(home: home)
        startWatch()
        startHeartbeat()
        openSession(home: home, from: origin)
    }

    // MARK: - 서버 세션

    /// 서버에 귀가 시작을 알린다. 서버는 이때 가족들에게 알림을 띄운다.
    ///
    /// 실패해도 귀가 자체는 계속된다. 본인 화면은 로컬로 살아 있고,
    /// 위치 보고가 다시 성공하면 그때 따라잡을 수 있기 때문이다.
    /// 다만 가족은 그동안 아무것도 못 보므로 화면에 상태를 남긴다.
    private func openSession(home: HomePlace, from origin: CLLocation) {
        let request = SessionStartRequest(
            home: .init(home),
            travelerName: travelerName,
            safetyMode: safetyMode,
            routeId: selectedRouteID,
            // 경로가 있으면 도착예정의 주인은 그 경로다. 그때는 적어 둔 시간을
            // 보내지 않는다 — 서버도 보지 않고, 요청에 둘이 같이 있으면 어느 쪽이
            // 이기는지 읽는 사람이 알 수 없다.
            plannedMinutes: selectedRouteID == nil ? plannedMinutes : nil,
            // 출발 자리. 아래 `report(origin, ...)` 로 보내는 것과 같은 좌표지만,
            // 그 보고는 세션이 만들어진 **뒤에** 나간다 — 그 사이에 가족 카드가
            // 먼저 뜨고, 좌표가 없으면 지도 없는 카드가 된다.
            lat: origin.coordinate.latitude,
            lon: origin.coordinate.longitude,
            checkInInterval: safetyMode ? checkInInterval : nil
        )
        Task { [sessions] in
            do {
                let id = try await sessions.start(request)
                self.sessionID = id
                HomecomingLog.push.notice("세션 시작 id=\(id, privacy: .public)")
                await self.report(origin, home: home, force: true)
            } catch {
                self.lastError = "가족에게 알리지 못했습니다: \(error.localizedDescription)"
                HomecomingLog.push.error("세션 시작 실패: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 위치 보고. 실패한 것은 다시 보내지 않는다 — 다음 위치가 곧 그것을 대신한다.
    private func report(_ location: CLLocation, home: HomePlace, force: Bool = false) async {
        guard let sessionID else { return }
        guard force || shouldReport(location, home: home) else { return }

        lastReportOrigin = location
        lastReportedAt = Date()

        do {
            // **응답에 실려 온 상태를 바로 앉힌다.** 이 폰은 남은거리·진행도를
            // 푸시로만 받아서, 늦으면 자기 GPS 로 찍은 점과 어긋났다. 보고가 이미
            // 오가는 요청이니 그 응답으로 따라잡는다 — 푸시는 그대로 두고,
            // 늦게 오면 같은 값이라 `adopt` 가 알아서 건너뛴다.
            if let state = try await sessions.report(
                sessionID: sessionID, location: SessionLocation(location)) {
                await activity.adopt(state)
            }
        } catch SessionError.gone {
            // 서버가 이 세션을 끝냈다. 붙잡고 있으면 위치를 영영 죽은 곳으로 보내고
            // 가족은 아무것도 못 본다. ID 를 버리고 새로 연다 — 귀가는 계속 중이니까.
            HomecomingLog.push.notice("세션이 서버에서 끝났다. 새로 연다 id=\(sessionID, privacy: .public)")
            self.sessionID = nil
            openSession(home: home, from: location)
        } catch {
            HomecomingLog.push.error("위치 보고 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldReport(_ location: CLLocation, home: HomePlace) -> Bool {
        guard let last = lastReportedAt, let origin = lastReportOrigin else { return true }
        let nearHome = location.distance(from: home.location) <= nearHomeRadius
        let interval = nearHome ? reportMinIntervalNearHome : reportMinInterval
        let displacement = nearHome ? reportMinDisplacementNearHome : reportMinDisplacement

        if Date().timeIntervalSince(last) >= interval { return true }
        if location.distance(from: origin) >= displacement { return true }
        return false
    }

    /// 카드의 새로고침을 눌렀다. 버스 도착만 다시 물어 화면에 앉힌다.
    ///
    /// **위치를 보내지 않는다.** 새로 알고 싶은 것은 버스이지 내 자리가 아니고,
    /// 여기서 보고를 만들면 접근 속도 계산에 제자리 픽스가 한 건 섞인다.
    func refreshBusArrival() async {
        guard let sessionID else { return }
        do {
            if let state = try await sessions.refreshBusArrival(sessionID: sessionID) {
                await activity.adopt(state)
            }
        } catch {
            HomecomingLog.push.error("버스 도착 새로고침 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func closeSession(_ reason: SessionEndReason) {
        guard let sessionID else { return }
        self.sessionID = nil
        Task { [sessions] in
            do {
                try await sessions.end(sessionID: sessionID, reason: reason)
                HomecomingLog.push.notice("세션 종료 \(reason.rawValue, privacy: .public)")
            } catch SessionError.gone {
                // 서버가 이미 끝냈다. 끝내려던 것이 끝나 있으니 실패가 아니다.
                HomecomingLog.push.notice("세션이 이미 끝나 있었다 id=\(sessionID, privacy: .public)")
            } catch {
                HomecomingLog.push.error("세션 종료 실패: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 앱이 재시작됐는데 액티비티가 아직 살아 있으면 추적을 다시 켠다.
    ///
    /// 이게 없으면 알림은 떠 있는데 값이 영원히 그대로인 유령 상태가 된다.
    /// 귀가 중에 앱이 메모리에서 내려가는 건 예외가 아니라 기본값이다.
    func resumeIfNeeded() {
        // **액티비티가 사라졌는데 서버 세션이 남아 있으면 그 세션을 닫는다.**
        //
        // iOS 는 앱을 강제 종료하면 그 앱의 Live Activity 도 끝낸다. 그러면 아래
        // 가드에서 빠져나가고, **서버에는 "진행 중" 세션이 영구히 남는다.** 그 세션이
        // 다음 귀가에 재사용되면 경과 시간이 몇 시간으로 잡혀 도착예정이 통째로
        // 어긋난다 — 2026-08-19 에 실제로 그렇게 됐다(서버의
        // `SESSION_REUSE_MAX_HOURS` 주석 참고. 그쪽에서도 나이로 막았지만, 애초에
        // 남기지 않는 게 맞다).
        //
        // 메모리 압박으로 iOS 가 앱을 내린 경우에는 액티비티가 살아 있으므로 여기
        // 오지 않는다. 여기 오는 것은 사실상 사용자가 앱을 강제 종료한 경우다 —
        // 그건 "그만" 이라는 뜻이니 닫는 것이 맞다. 카드가 없으니 되살릴 화면도 없다.
        if !isRunning {
            if let orphan = UserDefaults.standard.string(forKey: Self.sessionIDKey) {
                // `closeSession` 은 메모리의 `sessionID` 를 본다. 콜드 스타트에서는
                // 그게 아직 nil 이라, 먼저 채우지 않으면 조용히 아무것도 안 한다.
                sessionID = orphan
                HomecomingLog.location.notice(
                    "카드가 없는데 세션이 남아 있다 — 닫는다 id=\(orphan, privacy: .public)"
                )
                closeSession(.stopped)
            }
            return
        }

        guard let home, !tracker.isTracking else { return }
        finishing = false
        tracker.startTracking(home: home)
        startWatch()
        startHeartbeat()

        // 서버 세션도 같이 되살린다. 이게 없으면 위치 보고가 끊긴 채
        // 본인 화면만 멀쩡하고 가족 화면은 마지막 값에서 멈춘다.
        sessionID = UserDefaults.standard.string(forKey: Self.sessionIDKey)
        HomecomingLog.location.notice(
            "재시작 후 추적 재개 세션=\(self.sessionID ?? "없음", privacy: .public)"
        )
    }

    /// 도착 전에 사용자가 직접 끄는 경우.
    func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        watchTask?.cancel()
        watchTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        tracker.stopTracking()
        closeSession(.stopped)
        await activity.cancel()
        reset()
    }

    private func reset() {
        remainingMeters = nil
        lastEstimate = nil
        lastETARefresh = nil
        lastETAOrigin = nil
        finishing = false
        anomaly = nil
        watch.reset()
        pace.reset()
        publishedArrival = nil
        sessionID = nil
        lastReportedAt = nil
        lastReportOrigin = nil
    }

    // MARK: - 위치 수신

    private func handle(_ location: CLLocation) {
        guard let home, isRunning, !finishing else { return }

        let straight = location.distance(from: home.location)
        let nearHome = straight <= nearHomeRadius

        tracker.setPrecision(nearHome: nearHome)

        // 지오펜스가 늦게 울릴 수도 있으니 거리로도 도착을 판정한다.
        if straight <= home.arrivalRadius {
            handleArrival(reason: "거리")
            return
        }

        // 남은 거리는 마지막 경로 추정의 거리에서 그동안 좁힌 직선 거리만큼 뺀 값으로 근사한다.
        // 매 픽스마다 경로를 다시 계산하지 않으면서도 진행 바가 부드럽게 움직인다.
        let projected = projectedRemaining(straightToHome: straight)
        remainingMeters = projected

        // 관측은 **직선거리**로 잰다.
        //
        // 경로 기반 남은 거리(`projected`)는 ETA 를 새로 받을 때마다 기준점이 재설정된다.
        // 그 값으로 속도를 재면 갱신 주기가 관측 창을 계속 잘라 먹어 아무것도 못 잰다.
        // 직선거리는 누가 다시 계산해도 같은 값이라 그런 리셋이 없다.
        pace.note(remainingMeters: straight)

        if shouldRefreshETA(at: location, nearHome: nearHome) {
            scheduleETARefresh(from: location, to: home)
        }

        if safetyMode {
            watch.note(location)
            refreshAnomaly(distanceToHome: straight)
        }

        pushUpdate(remainingMeters: projected, home: home)
        Task { await report(location, home: home) }
    }

    /// 마지막 경로 거리를 기준으로, 직선 거리가 줄어든 만큼 함께 줄인다.
    /// 경로 거리가 직선보다 짧아지는 역전은 막는다.
    private func projectedRemaining(straightToHome straight: CLLocationDistance) -> Int {
        guard let estimate = lastEstimate, let origin = lastETAOrigin, let home else {
            return Int(straight.rounded())
        }
        let straightAtEstimate = origin.distance(from: home.location)
        let closed = straightAtEstimate - straight
        let projected = Double(estimate.routeMeters) - closed
        return Int(max(straight, projected).rounded())
    }

    /// 액티비티에 지금 값을 밀어 넣는다.
    ///
    /// **경로로 도는 귀가면 앱이 아는 건 이상 상황뿐이다.** 남은거리·도착예정·수단·
    /// 문구는 서버가 경로를 따라 재서 민다. 앱이 든 값은 출발 시점에 굳은 것이라
    /// 여기서 같이 밀면 서버가 민 최신값을 옛것으로 덮는다 — 2026-08-14 실주행에서
    /// 집 앞 760m 에서도 "국회의사당역까지 5분"(첫 구간)이 떴다.
    ///
    /// 서버는 위치 보고마다 민다. 같은 실주행에서 165번 전부 두 기기에 닿았으니
    /// 앱이 거들 자리가 없다. 이상 상황만 서버가 모른다(`content_state` 에 없다).
    private func pushUpdate(remainingMeters meters: Int, home: HomePlace) {
        guard let estimate = lastEstimate else { return }
        // **도착예정의 주인이 서버인 경우.** 저장된 경로(실측 시간)와 귀가자가
        // 적은 시간이 그렇다. 둘 다 "아는 값" 이라 관측으로 보정하면 안 된다 —
        // `publishableArrival` 은 관측 속도로 시각을 흔드는 함수다.
        let onRoute = estimate.source == .savedRoute || estimate.source == .traveler
        let arrival = onRoute ? nil : publishableArrival(base: estimate.expectedArrival)
        // **좌표는 경로 여부와 무관하게 넘긴다.** 위의 nil 들과 다른 값이다 —
        // 남은거리·문구는 서버가 경로를 따라 재므로 앱이 거들면 옛값으로 덮지만,
        // 지금 자리는 이 기기의 GPS 가 원본이다. 서버도 이 값을 받아서 다시 보낸다.
        //
        // **잰 시각도 함께 넘긴다.** 좌표만 넘기고 시각을 두고 오면, 화면은 이 기기의
        // GPS 로 그린 자리를 보여 주면서 나이는 서버 푸시가 닿은 시각으로 말한다.
        let here = tracker.lastLocation?.coordinate
        let heresTime = tracker.lastLocation?.timestamp
        Task { [activity] in
            await activity.update(
                remainingMeters: onRoute ? nil : meters,
                expectedArrival: arrival,
                transport: onRoute ? nil : estimate.transport,
                detail: onRoute ? nil : estimate.detail,
                arrivalRadius: Int(home.arrivalRadius),
                anomaly: anomaly,
                coordinate: here,
                measuredAt: heresTime,
                home: home.coordinate,
                homeRadius: Int(home.arrivalRadius)
            )
        }
    }

    /// 관측으로 보정하되, 몇 초짜리 흔들림은 내보내지 않는다.
    /// 도착 예정이 매번 조금씩 바뀌면 카운트다운이 앞뒤로 튀어 신뢰를 잃는다.
    private func publishableArrival(base: Date) -> Date {
        // 관측과 같은 척도(직선거리)로 남은 시간을 계산해야 앞뒤가 맞는다.
        guard let straight = distanceToHome() else { return base }
        let corrected = pace.corrected(base: base, remainingMeters: Int(straight))

        if let published = publishedArrival,
           abs(corrected.timeIntervalSince(published)) < arrivalJitterThreshold {
            return published
        }

        publishedArrival = corrected
        if let kph = pace.observedKilometersPerHour() {
            HomecomingLog.eta.debug(
                "보정 관측=\(kph, format: .fixed(precision: 1))km/h 반영=\(self.pace.weight(), format: .fixed(precision: 2)) 기준대비=\(Int(corrected.timeIntervalSince(base)))초"
            )
        }
        return corrected
    }

    // MARK: - 안전귀가

    /// 앱 안에서 안심 확인을 누른 경우.
    func checkIn() async {
        await activity.checkIn(interval: checkInInterval)
        if anomaly == .unresponsive { anomaly = nil }
    }

    /// 위치가 오지 않아도 판정이 돌게 하는 주기 루프.
    ///
    /// '멈춰 있음'과 '무응답'은 아무 일도 일어나지 않을 때 성립한다.
    /// 위치 콜백에만 기대면 정확히 그 상황에서 아무도 눈치채지 못한다.
    /// 안 움직여도 몇 분마다 같은 자리를 다시 보낸다.
    ///
    /// **`distanceFilter` 가 150m 라 제자리에 서 있으면 폰이 아무것도 안 보낸다.**
    /// 2026-08-14 실주행 실측(68분, 갱신 165건)에서 2분 넘게 끊긴 다섯 번이 전부
    /// 정류장에서 버스를 기다리거나 역에서 열차를 기다린 시간이었다 — 가장 긴 것이
    /// 7.6분이다. 신호 문제가 아니었다. 지하철 구간(경의중앙선, 지상)이 오히려 가장
    /// 촘촘했다: 갱신 81건에 중앙 간격 8초.
    ///
    /// 그동안 가족 화면에는 "N분 전 확인" 이 떴다. **어디 있는지 아는데 모른다고
    /// 말한 셈이다.** 이게 붙으면 그 문구는 진짜 신호 두절에서만 뜬다.
    ///
    /// 새 위치를 만들어 내지 않는다. 마지막으로 **실제로 받은** 자리를 다시 보낼
    /// 뿐이다 — 아는 것만 말한다는 원칙은 그대로다.
    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatSeconds))
                guard let self, !Task.isCancelled else { return }
                await self.beat()
            }
        }
    }

    /// 마지막 보고가 오래됐을 때만 보낸다. 움직이는 동안에는 아무 일도 안 한다.
    private func beat() async {
        guard let home, let location = tracker.lastLocation else { return }
        if let last = lastReportedAt,
           Date().timeIntervalSince(last) < Self.heartbeatSkipSeconds { return }
        HomecomingLog.location.notice("heartbeat — 제자리 보고")
        await report(location, home: home, force: true)
    }

    private func startWatch() {
        guard safetyMode, watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard let self, !Task.isCancelled else { return }
                self.refreshAnomaly(distanceToHome: self.distanceToHome())
            }
        }
    }

    private func distanceToHome() -> CLLocationDistance? {
        guard let home, let location = tracker.lastLocation else { return nil }
        return location.distance(from: home.location)
    }

    /// 판정이 바뀔 때만 액티비티를 건드린다. 같은 값을 계속 밀면 아일랜드가 계속 펼쳐진다.
    private func refreshAnomaly(distanceToHome distance: CLLocationDistance?) {
        guard safetyMode, isRunning, !finishing else { return }
        guard let state = activity.activity?.content.state, let home else { return }

        let next = watch.anomaly(
            expectedArrival: state.expectedArrival,
            checkInDeadline: state.checkInDeadline,
            distanceToHome: distance
        )
        guard next != anomaly else { return }

        anomaly = next
        HomecomingLog.location.notice("이상 상황 \(next?.rawValue ?? "해소", privacy: .public)")

        guard let meters = remainingMeters else { return }
        pushUpdate(remainingMeters: meters, home: home)
    }

    // MARK: - ETA 갱신

    private func shouldRefreshETA(at location: CLLocation, nearHome: Bool) -> Bool {
        guard refreshTask == nil else { return false }

        // **경로로 도는 귀가는 다시 추정하지 않는다.**
        //
        // `startingEstimate()` 가 이미 경로의 실측 소요시간을 답으로 정했다. 여기서
        // 다시 부르면 `scheduleETARefresh` 가 `estimateOrFallback` 을 타고, 그건
        // 경로를 모르니 MapKit 자동차 경로를 준다. 82분짜리 귀가가 19분으로 덮인다.
        //
        // 2026-08-14 실주행에서 실제로 그렇게 됐다. 출발 5분 뒤 카드에 "18분 30초 ·
        // 17:57 도착 · 차량 · MapKit" 이 떴는데, **같은 카드의 노선도는 "지하철 38분"
        // 을 그리고 있었다.** 서버는 처음부터 82분으로 알고 있었다.
        //
        // 경로가 있으면 남은 시간의 주인은 서버다. 경로를 따라 재고 밀린 시간까지
        // 계산해 푸시한다. 앱이 할 일은 위치를 보고하는 것뿐이다.
        // **귀가자가 적은 시간도 같다.** 다시 추정하면 사람이 적은 값을 MapKit
        // 자동차 경로로 덮어쓴다 — 그 값을 안 쓰려고 물어본 것이다.
        if lastEstimate?.source == .savedRoute || lastEstimate?.source == .traveler {
            return false
        }

        guard let last = lastETARefresh, let origin = lastETAOrigin else { return true }

        let interval = nearHome ? etaMinIntervalNearHome : etaMinInterval
        let displacement = nearHome ? etaMinDisplacementNearHome : etaMinDisplacement

        if Date().timeIntervalSince(last) >= interval { return true }
        if location.distance(from: origin) >= displacement { return true }
        return false
    }

    private func scheduleETARefresh(from location: CLLocation, to home: HomePlace) {
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let estimate = await self.estimateOrFallback(from: location.coordinate, to: home.coordinate)
            guard !Task.isCancelled else { return }

            // **거리는 직선으로 되돌린다.** 위 `startingEstimate` 와 같은 이유다 —
            // 경로가 없는 귀가에서 서버는 직선으로 재므로, 추정이 준 거리(직선×1.35
            // 또는 자동차 경로)를 그대로 밀면 앱과 서버가 같은 필드를 서로 다른 자로
            // 번갈아 덮어쓴다. 도착예정·수단·문구는 추정이 준 것을 그대로 쓴다.
            let straight = Int(location.distance(from: home.location))
            let corrected = ETAEstimate(
                expectedArrival: estimate.expectedArrival,
                routeMeters: straight,
                transport: estimate.transport,
                detail: estimate.detail,
                source: estimate.source,
                routeShape: estimate.routeShape
            )

            self.lastEstimate = corrected
            self.lastETARefresh = Date()
            self.lastETAOrigin = location
            self.remainingMeters = corrected.routeMeters
            self.publishedArrival = nil   // 기준선이 바뀌었으니 흔들림 억제를 푼다
            self.refreshTask = nil

            self.pushUpdate(remainingMeters: corrected.routeMeters, home: home)
        }
    }

    /// 귀가를 시작할 때 카드에 넣을 도착예정.
    ///
    /// **경로를 골랐으면 그 실측 소요시간이 답이다.** 추정할 것이 없다 — 대중교통
    /// 앱이 이미 "1시간 24분" 이라고 알려 줬고 사용자가 그걸 저장해 뒀다.
    /// 여기서 MapKit 을 부르면 자동차 경로가 나오고, 카드가 20분으로 떴다가
    /// 서버 푸시를 받고 84분으로 튄다. 그 튐을 없애려고 경로 기능을 만들었다.
    ///
    /// 거리는 여전히 추정으로 채운다. 진행 바에만 쓰이는 값이고, 경로에는 총
    /// 거리가 없다(구간 좌표열은 있지만 그걸 합치는 건 서버가 할 일이다).
    private func startingEstimate(from origin: CLLocation, to home: HomePlace) async -> ETAEstimate {
        let fallback = await estimateOrFallback(from: origin.coordinate, to: home.coordinate)

        guard let routeID = selectedRouteID,
              let route = selectedRoute?(routeID),
              route.totalSeconds > 0
        else {
            // 경로가 없다. **귀가자가 적은 시간이 있으면 그것을 쓴다** — 추정보다
            // 사람이 아는 값이 낫다(`ETAEstimate.Source.traveler` 주석 참고).
            //
            // **거리는 언제나 직선이다.** 서버가 경로 없는 귀가를 그렇게 재기
            // 때문이다(`recompute` 의 `straight`). 추정이 준 거리를 그대로 쓰면
            // 같은 필드에 두 개의 자가 섞인다 — `/eta` 는 직선×1.35 를 주고
            // (`handle_eta`), MapKit 은 자동차 경로 거리를 준다. 둘 다 직선보다
            // 커서 카드에 **직선거리로는 나올 수 없는 값**이 뜨고, 서버 갱신이
            // 닿는 순간 확 줄어든다(2026-08-21 실기기에서 그렇게 보였다).
            //
            // 경로가 있는 쪽은 이미 같은 규칙을 지킨다(아래 `along`) — "앱도 서버와
            // 같은 자로 재야 첫 갱신에서 튀지 않는다".
            let straight = Int(home.location.distance(from: origin))
            guard let minutes = plannedMinutes, minutes > 0 else {
                return ETAEstimate(
                    expectedArrival: fallback.expectedArrival,
                    routeMeters: straight,
                    transport: fallback.transport,
                    detail: fallback.detail,
                    source: fallback.source
                )
            }
            return ETAEstimate(
                expectedArrival: Date().addingTimeInterval(TimeInterval(minutes * 60)),
                routeMeters: straight,
                transport: fallback.transport,
                detail: nil,
                source: .traveler
            )
        }

        // 거리는 **경로를 따라간 길이**다. 서버가 그렇게 재고, 앱도 같아야 첫
        // 갱신에서 튀지 않는다.
        //
        // 직선도 자동차 경로도 아니다. 직선(19km)은 이 경로처럼 집 쪽으로 곧장
        // 가지 않는 경로에서 진행 바를 한참 멈춰 있게 만들고, 자동차 경로(26.4km)는
        // 타지도 않는 길이다. 경로 자체가 28.4km 라고 말해 준다.
        let along = route.totalMeters ?? Int(home.location.distance(from: origin))

        // 교통수단과 문구도 경로에서 온다. 이걸 폴백에서 가져오면 걸어서 역까지
        // 가는 첫 6분에 카드가 "차량 탑승" 으로 뜬다.
        return ETAEstimate(
            expectedArrival: Date().addingTimeInterval(TimeInterval(route.totalSeconds)),
            routeMeters: along,
            transport: route.firstTransport ?? fallback.transport,
            detail: route.firstDetail,
            source: .savedRoute,
            // 노선도도 경로에서 온다. 도착예정·수단·거리와 같은 출처여야
            // 카드와 노선도가 어긋나지 않는다.
            //
            // 서버(`summary()`)에서 `totalMeters`·`firstTransport`·`firstDetail`·
            // `stops` 넷은 같은 `legs` 파싱 게이트를 공유한다 — 파싱이 실패하면
            // 넷 다 응답에서 함께 빠진다. 그러니 `stops == nil` 은 "정류장이 없다"가
            // 아니라 "경로를 못 읽었다"는 뜻이고, 이미 위에서 `?? fallback`/
            // `?? Int(...)` 로 다루는 형제 필드들과 같은 신호다. 여기서만 다르게
            // 다룰 이유가 없다.
            routeShape: route.stops.map { HomecomingAttributes.RouteShape(stops: $0) }
        )
    }

    /// 모든 제공자가 실패해도 값을 하나는 만들어 낸다.
    /// Live Activity 는 도착할 때까지 화면에 남아 있어야 하므로, 여기서 던지면 안 된다.
    private func estimateOrFallback(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> ETAEstimate {
        do {
            return try await eta.estimate(from: origin, to: destination)
        } catch {
            lastError = error.localizedDescription
            return (try? await DeadReckoningETAProvider().estimate(from: origin, to: destination))
                ?? ETAEstimate(
                    expectedArrival: Date().addingTimeInterval(15 * 60),
                    routeMeters: Int(origin.straightLineDistance(to: destination).rounded()),
                    transport: .subway,
                    detail: nil,
                    source: .deadReckoning
                )
        }
    }

    // MARK: - 도착

    private func handleArrival(reason: String) {
        guard isRunning, !finishing else { return }
        finishing = true
        HomecomingLog.location.notice("도착 판정 (\(reason, privacy: .public))")

        refreshTask?.cancel()
        refreshTask = nil
        watchTask?.cancel()
        watchTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        remainingMeters = 0
        // 도착을 유발한 그 위치다. `stopTracking()` 뒤에도 남아 있으므로 아래에서
        // 도착 화면의 지도에 그대로 실어 보낸다.
        let arrivedAt = tracker.lastLocation?.coordinate
        tracker.stopTracking()
        closeSession(.arrived)

        Task { [activity] in
            await activity.finish(coordinate: arrivedAt)
            self.reset()
        }
    }

    // MARK: - 보조

    /// 귀가를 시작하기 위한 첫 픽스. 이미 신선한 게 있으면 바로 돌려준다.
    private func waitForLocation(timeout: TimeInterval) async -> CLLocation? {
        if let location = tracker.lastLocation,
           Date().timeIntervalSince(location.timestamp) < 60 {
            return location
        }

        // 곧 추적을 켤 참이므로 단발 요청 대신 추적을 먼저 켜서 픽스를 받는다.
        if let home { tracker.startTracking(home: home) }
        return await pollLocation(timeout: timeout)
    }

    /// 집 등록처럼 추적과 무관한 자리에서 픽스 하나를 받아 온다.
    private func awaitLocation(timeout: TimeInterval) async -> CLLocation? {
        // **여기도 나이를 본다.** 집은 한 번 정하면 계속 쓰는 값이라, 낡은 픽스로
        // 정하면 도착 판정과 가족 지도가 통째로 어긋난다.
        if let location = tracker.lastLocation,
           Date().timeIntervalSince(location.timestamp) < 60 {
            return location
        }
        tracker.requestOneShotLocation()
        return await pollLocation(timeout: timeout)
    }

    /// 픽스 하나를 기다린다. **낡은 값은 안 받는다.**
    ///
    /// `CLLocationManager` 는 마지막으로 알던 자리를 계속 들고 있다. 그래서
    /// `lastLocation` 이 있다는 것은 "지금 어디인지 안다" 는 뜻이 아니다 — 몇 시간
    /// 전 자리일 수 있다.
    ///
    /// 이 검사가 없어서 실제로 틀렸다(2026-08-21). `waitForLocation` 은 60초보다
    /// 낡은 픽스를 걸렀는데, 걸러 낸 뒤 부르는 이 함수가 **그 같은 값을 즉시**
    /// 돌려줬다. 집에서 잡힌 옛 픽스가 출발 좌표가 되어 일산에서 귀가를 시작했을 때
    /// 남은거리가 비정상적으로 짧게 떴고, 새 픽스가 들어온 뒤 다시 누르면 맞았다.
    ///
    /// **낡은 값을 돌려주지 않는다.** 못 잡으면 nil 이고, 부르는 쪽이 시작을
    /// 거절한다 — 틀린 거리를 그리는 것보다 "아직 위치를 못 잡았다" 가 낫다.
    /// 사용자가 다시 누르면 그때는 추적이 켜져 있어 대개 바로 잡힌다.
    private func pollLocation(timeout: TimeInterval, maxAge: TimeInterval = 60) async -> CLLocation? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let location = tracker.lastLocation,
               Date().timeIntervalSince(location.timestamp) < maxAge {
                return location
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let stale = tracker.lastLocation {
            HomecomingLog.location.warning(
                "픽스가 낡았다 \(Int(Date().timeIntervalSince(stale.timestamp)))초 전 — 쓰지 않는다")
        }
        return nil
    }
}
