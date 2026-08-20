import CoreLocation
import Foundation
import Observation

/// 귀가 중 위치를 추적한다.
///
/// 두 겹으로 돌린다.
/// - **연속 업데이트**: 앱이 살아 있는 동안 정밀하게. 남은 거리와 ETA 를 갱신하는 주 경로.
/// - **중요 위치 변경**: 앱이 종료·중단돼도 시스템이 다시 깨워 준다. 귀가 내내 붙잡아 두는 보험.
/// - **지오펜스**: 집 반경 진입은 별도로 감시한다. 도착 판정만큼은 늦으면 안 되기 때문.
@MainActor
@Observable
final class HomecomingLocationTracker: NSObject {

    enum Authorization: Equatable {
        case notDetermined
        case denied
        case whenInUse
        case always

        /// 백그라운드 추적까지 가능한 상태인지.
        var allowsBackground: Bool { self == .always }
    }

    // MARK: 상태

    private(set) var authorization: Authorization = .notDetermined
    private(set) var lastLocation: CLLocation?
    private(set) var lastError: String?
    private(set) var isTracking = false

    /// 단발 위치를 기다리는 중. 버튼이 왜 아직 안 되는지 화면에 설명하기 위한 값.
    private(set) var isLocating = false

    /// 권한이 없어 미뤄 둔 단발 요청.
    private var wantsOneShot = false

    /// 위치가 갱신될 때마다.
    var onLocation: ((CLLocation) -> Void)?
    /// 집 지오펜스 진입.
    var onArrivedHome: (() -> Void)?

    // MARK: 내부

    private let manager = CLLocationManager()
    private var monitorTask: Task<Void, Never>?
    private var monitoredHome: HomePlace?
    private var home: HomePlace?

    /// CLMonitor 는 같은 이름으로 두 번 만들면 ObjC 예외를 던진다 — Swift 에서 잡을 수 없다.
    /// 그래서 생성 자체를 한 번으로 묶어 두고 모두가 이 태스크의 결과를 나눠 쓴다.
    private var monitorSetup: Task<CLMonitor, Never>?

    private static let monitorName = "HomecomingHomeMonitor"
    private static let homeConditionID = "home"

    override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 150
        authorization = Self.map(manager.authorizationStatus)
    }

    // MARK: - 권한

    /// 먼저 '사용 중'을, 이미 받았으면 '항상'을 요청한다.
    /// 처음부터 '항상'을 물으면 iOS 가 '사용 중' 시트만 띄우므로 두 단계로 나눈다.
    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: - 추적

    /// 픽스 하나만 받는다.
    ///
    /// 집을 등록하려면 현재 위치가 있어야 하는데, 추적은 귀가가 시작돼야 켜진다.
    /// 그 사이의 공백을 메운다.
    ///
    /// 첫 실행에서는 권한 시트가 아직 떠 있어 여기서 바로 요청할 수 없다.
    /// 그래서 요청을 기억해 뒀다가 권한이 떨어지는 순간 이어서 보낸다 —
    /// 이게 없으면 사용자가 '허용'을 눌러도 위치를 영영 못 받는다.
    func requestOneShotLocation() {
        guard authorization == .whenInUse || authorization == .always else {
            wantsOneShot = true
            requestAuthorization()
            return
        }
        wantsOneShot = false
        isLocating = true
        manager.requestLocation()
    }

    func startTracking(home: HomePlace) {
        self.home = home
        lastError = nil

        guard authorization == .whenInUse || authorization == .always else {
            lastError = "위치 권한이 필요합니다."
            requestAuthorization()
            return
        }

        // '항상'이 아닐 때 이 값을 켜면 런타임 예외가 난다.
        manager.allowsBackgroundLocationUpdates = authorization.allowsBackground

        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        startHomeMonitor(home: home)

        isTracking = true
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        monitorTask?.cancel()
        monitorTask = nil
        stopHomeMonitor()
        isTracking = false
    }

    /// 집에 가까워지면 정밀도를 올린다. 먼 구간에서 미터 단위로 켜 두면 배터리만 태운다.
    func setPrecision(nearHome: Bool) {
        manager.desiredAccuracy = nearHome ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = nearHome ? 25 : 150
    }

    // MARK: - 지오펜스

    /// 여러 번 불러도 안전하다. 같은 집이면 아무것도 하지 않는다.
    private func startHomeMonitor(home: HomePlace) {
        guard monitoredHome != home || monitorTask == nil else { return }
        monitoredHome = home

        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            let monitor = await self.sharedMonitor()

            // 이전 실행이나 이전 집에서 남은 조건을 걷어내고 다시 건다.
            for identifier in await monitor.identifiers {
                await monitor.remove(identifier)
            }
            guard !Task.isCancelled else { return }
            await monitor.add(
                CLMonitor.CircularGeographicCondition(center: home.coordinate, radius: home.arrivalRadius),
                identifier: Self.homeConditionID
            )

            do {
                for try await event in await monitor.events {
                    guard !Task.isCancelled else { return }
                    guard event.identifier == Self.homeConditionID else { continue }
                    if event.state == .satisfied {
                        self.onArrivedHome?()
                    }
                }
            } catch {
                self.lastError = "지오펜스 감시 실패: \(error.localizedDescription)"
            }
        }
    }

    /// 프로세스당 하나. 두 번째 호출은 첫 번째 생성이 끝나기를 기다렸다가 같은 것을 받는다.
    private func sharedMonitor() async -> CLMonitor {
        if let monitorSetup { return await monitorSetup.value }
        let setup = Task { await CLMonitor(Self.monitorName) }
        monitorSetup = setup
        return await setup.value
    }

    private func stopHomeMonitor() {
        monitoredHome = nil
        guard let monitorSetup else { return }
        Task {
            let monitor = await monitorSetup.value
            for identifier in await monitor.identifiers {
                await monitor.remove(identifier)
            }
        }
    }

    // MARK: - 매핑

    fileprivate static func map(_ status: CLAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorizedAlways: return .always
        case .authorizedWhenInUse: return .whenInUse
        default: return .denied
        }
    }

    fileprivate func apply(status: CLAuthorizationStatus) {
        authorization = Self.map(status)

        // 추적 중에 '사용 중' → '항상' 으로 승격되면 그때 백그라운드를 연다.
        if isTracking {
            manager.allowsBackgroundLocationUpdates = authorization.allowsBackground
        }

        switch authorization {
        case .whenInUse, .always:
            lastError = nil
            // 권한 시트 때문에 미뤄 뒀던 요청을 이제 보낸다.
            if wantsOneShot { requestOneShotLocation() }
            // 추적 중이었는데 권한이 없어 멈춰 있었다면 이어서 켠다.
            if let home, !isTracking { startTracking(home: home) }
        case .denied:
            wantsOneShot = false
            isLocating = false
            lastError = "설정에서 위치 권한을 허용해 주세요."
        case .notDetermined:
            break
        }
    }

    fileprivate func ingest(_ locations: [CLLocation]) {
        // 캐시된 오래된 픽스와 정확도가 형편없는 픽스는 버린다.
        //
        // 다만 아직 아무 위치도 없을 때는 기준을 풀어 준다.
        // 집을 등록하려는 사용자에게는 300m 오차의 위치라도 있는 편이
        // 아무것도 없어서 버튼이 안 눌리는 것보다 훨씬 낫다.
        let bootstrapping = lastLocation == nil
        let maxAccuracy: CLLocationAccuracy = bootstrapping ? 1_000 : 200
        let maxAge: TimeInterval = bootstrapping ? 300 : 60

        let now = Date()
        let usable = locations.filter { location in
            location.horizontalAccuracy >= 0
                && location.horizontalAccuracy <= maxAccuracy
                && now.timeIntervalSince(location.timestamp) < maxAge
        }
        guard let latest = usable.last else { return }

        isLocating = false
        lastError = nil
        lastLocation = latest
        onLocation?(latest)
    }

    fileprivate func ingest(error: Error) {
        isLocating = false

        if (error as? CLError)?.code == .denied {
            lastError = "위치 권한이 거부되었습니다."
            return
        }

        // 추적 중이라면 픽스를 한 번 놓치는 건 정상이라 조용히 넘어간다.
        // 하지만 아직 위치가 하나도 없으면 사용자가 이유를 알아야 한다 —
        // 안 그러면 '버튼이 안 먹는다'로만 보인다.
        guard lastLocation == nil else { return }
        lastError = "현재 위치를 확인하지 못했습니다. 실외에서 다시 시도해 주세요."
    }
}

// MARK: - CLLocationManagerDelegate

extension HomecomingLocationTracker: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.apply(status: status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.ingest(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.ingest(error: error) }
    }
}
