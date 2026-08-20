import Foundation
import Observation

/// 앱 구성 요소를 한 곳에서 조립한다.
///
/// 서버 주소는 Info.plist 의 `HomecomingBackendBaseURL` 에서 읽는다.
/// 값이 비어 있으면 서버 없이 도는 모드로 떨어진다 —
/// ETA 는 MapKit 으로, 토큰은 콘솔로. 서버 붙이기 전에도 앱이 돌아간다.
@MainActor
@Observable
final class HomecomingEnvironment {

    let activity = HomecomingActivityManager()
    let tracker: HomecomingLocationTracker
    let coordinator: HomecomingCoordinator
    let push: HomecomingPushRegistrar
    let pairing: PairingStore
    let routes: RouteStore
    let watching = WatchingStore()

    /// 가족 지도에 그릴 경로. 세션마다 서버에서 한 번 받아 둔다.
    let routeGeometry: RouteGeometryStore
    let simulator: CommuteSimulator

    /// 서버가 붙어 있는지. 화면에 상태를 보여 주는 용도.
    let backendBaseURL: URL?

    /// 이 기기의 자격. 통신 계층들이 이 상자를 나눠 쓴다.
    ///
    /// 앱이 켜질 때 키체인에 있는 걸 넣고, 없으면 `registerIfNeeded()` 가 서버에
    /// 등록해서 채운다. 등록 전에 나간 요청은 서버가 401 을 준다 — 조용히 남의
    /// 계정으로 처리되는 것보다 그게 낫다.
    let auth: HomecomingAuth

    init() {
        let baseURL = Self.configuredBackendURL()
        backendBaseURL = baseURL

        let auth = HomecomingAuth(HomecomingCredentialStore.load())
        self.auth = auth

        let tracker = HomecomingLocationTracker()
        self.tracker = tracker

        // 서버가 없으면 이 귀가는 본인 기기에만 뜬다. 가족은 못 본다.
        let sessions: SessionReporting =
            baseURL.map { RemoteSessionReporter(baseURL: $0, auth: auth) }
            ?? LocalOnlySessionReporter()

        coordinator = HomecomingCoordinator(
            activity: activity,
            tracker: tracker,
            eta: HomecomingCoordinator.makeDefaultETAProvider(backendBaseURL: baseURL),
            sessions: sessions
        )

        let backend: HomecomingBackend =
            baseURL.map { RemoteHomecomingBackend(baseURL: $0, auth: auth) }
            ?? ConsoleHomecomingBackend()
        push = HomecomingPushRegistrar(backend: backend)

        pairing = PairingStore(
            client: baseURL.map { RemotePairingClient(baseURL: $0, auth: auth) }
                ?? UnavailablePairingClient(),
            isAvailable: baseURL != nil
        )

        routes = RouteStore(
            client: baseURL.map { RemoteRouteClient(baseURL: $0, auth: auth) }
                ?? UnavailableRouteClient(),
            isAvailable: baseURL != nil
        )

        simulator = CommuteSimulator(manager: activity)

        // 서버가 없으면 받아 올 곳도 없다. 그때는 지도가 점만 찍는다.
        routeGeometry = RouteGeometryStore(baseURL: baseURL, auth: auth)

        // 코디네이터가 고른 경로를 볼 수 있게 한다. 이게 없으면 귀가를 시작한
        // 순간의 카드가 경로를 무시하고 MapKit 자동차 추정으로 뜬다 — 시간도,
        // 교통수단도.
        let routes = routes
        coordinator.selectedRoute = { [weak routes] id in routes?.route(id: id) }
    }

    private static func configuredBackendURL() -> URL? {
        // 런치 인자가 Info.plist 를 이긴다. 스테이징·목 서버로 갈아 끼울 때 쓴다.
        //   xcrun simctl launch <udid> com.kona.homecoming2 -homecomingBackend http://localhost:8787
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-homecomingBackend"),
           index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            return url
        }

        guard let raw = Bundle.main.object(forInfoDictionaryKey: "HomecomingBackendBaseURL") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return URL(string: raw)
    }

    // MARK: - 기기 등록

    /// 자격이 없으면 서버에 등록해서 받아 온다. 앱 기동 직후 한 번 부른다.
    ///
    /// `-homecomingToken <token>` 으로 덮어쓸 수 있다. 기기 한 대로 귀가자와 가족
    /// 양쪽을 번갈아 시험하려면 이게 있어야 한다 — 화면을 탭할 수단이 없는
    /// 실기기 검증에서 계정을 갈아 끼우는 유일한 길이다.
    func registerIfNeeded() async {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-homecomingToken"), index + 1 < arguments.count {
            // 계정 id 는 서버가 토큰으로 찾는다. 여기서는 자리만 채운다.
            auth.set(HomecomingCredentials(accountID: "injected", token: arguments[index + 1]))
            print("[귀가마중] 토큰 주입됨")
            return
        }

        guard let baseURL = backendBaseURL else { return }

        // 등록은 `HomecomingAuth` 한 곳에서만 일어난다. 여기서 따로 등록하면
        // 앱이 뜨자마자 나가는 요청의 401 회복과 경주해서 계정이 두 개 생긴다.
        if await auth.ensureRegistered(baseURL: baseURL), let issued = auth.current {
            print("[귀가마중] 기기 등록 \(issued.accountID)")
        }
    }
}
