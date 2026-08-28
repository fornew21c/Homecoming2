import ActivityKit
import CoreLocation
import Foundation
import Observation
import UIKit

/// 귀가마중 Live Activity 의 수명주기를 한 곳에서 관리한다.
///
/// 앱은 이 매니저만 호출하고, 화면 그리기는 위젯 익스텐션이 맡는다.
/// 실서비스에서는 `start(...)` 에서 받은 push token 을 서버에 올려 두고
/// 이후 갱신은 서버가 ActivityKit push 로 보내는 형태가 된다.
/// (`update(...)` / `finish(...)` 는 로컬 갱신 경로 — 시뮬레이션과 폴백용.)
@MainActor
@Observable
final class HomecomingActivityManager {

    /// 현재 실행 중인 액티비티. 없으면 nil.
    private(set) var activity: Activity<HomecomingAttributes>?

    /// 지금 떠 있는 액티비티의 고정값. 화면이 노선도를 그리는 데 쓴다.
    ///
    /// 고정값(이름·목적지·노선도)은 시작 이후 안 바뀌므로 `activity` 만 관찰하면
    /// 충분하다 — `activity` 가 nil↔값 으로 바뀌는 순간(시작/종료)은 이미
    /// `@Observable` 이 잡아낸다.
    var currentAttributes: HomecomingAttributes? { activity?.attributes }

    /// 지금 떠 있는 액티비티의 갱신값. 화면이 노선도를 그리는 데 쓴다.
    ///
    /// `activity.content.state` 를 직접 읽지 않는다. `Activity` 자체는
    /// `@Observable` 이 아니라서, 서버 push 로 `content` 만 바뀌어도 이 매니저의
    /// `activity` 저장 속성 자체(참조)는 그대로다 — SwiftUI 는 그 변화를 못
    /// 알아챈다. 그래서 `contentUpdates` 스트림을 구독해 값을 이 저장 속성에
    /// 옮겨 담고, 이 속성을 관찰 대상으로 삼는다.
    private(set) var currentState: HomecomingAttributes.ContentState?

    /// `currentState` 를 채우는 구독. `activity` 가 새로 잡힐 때마다 다시 건다.
    private var contentObservation: Task<Void, Never>?

    /// 갱신을 서버가 밀어 줄지 여부.
    ///
    /// `.token` 으로 시작하면 액티비티마다 갱신 토큰이 발급되고,
    /// 앱이 잠들어도 서버가 APNs 로 새 상태를 밀어 넣을 수 있다.
    /// 로컬 `update(...)` 는 그와 별개로 계속 쓸 수 있다 — 두 경로는 배타적이지 않다.
    /// 데모(`CommuteSimulator`)처럼 전부 로컬로 도는 경우만 nil 로 둔다.
    var pushType: PushType? = .token

    /// 이 기기가 누구의 화면인가. 본인 기기는 `.traveler`,
    /// 서버가 push-to-start 로 띄우는 가족 기기는 `.watcher` 로 온다.
    var audience: HomecomingAttributes.Audience = .traveler

    /// 사용자가 설정에서 Live Activity 를 꺼 두었는지 여부.
    var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool { activity != nil }

    // MARK: - 시작

    enum StartError: LocalizedError {
        case notAuthorized
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "설정 > 귀가 마중 에서 '실시간 활동'을 켜 주세요."
            case .alreadyRunning:
                return "이미 귀가 알림이 진행 중이에요."
            }
        }
    }

    /// 귀가 시작을 눌렀을 때 호출.
    ///
    /// 남은 분이 아니라 도착 예정 **시각**을 받는다. 추정한 순간과 액티비티가 뜨는 순간
    /// 사이의 지연이 그대로 오차가 되기 때문이다. 시각으로 넘기면 그 지연이 사라진다.
    @discardableResult
    func start(
        travelerName: String,
        destinationName: String = "집",
        transport: HomecomingAttributes.Transport,
        totalMeters: Int,
        expectedArrival: Date,
        detail: String? = nil,
        routeShape: HomecomingAttributes.RouteShape? = nil,
        checkInDeadline: Date? = nil,
        sessionID: String? = nil,
        coordinate: CLLocationCoordinate2D? = nil,
        home: CLLocationCoordinate2D? = nil,
        homeRadius: Int? = nil
    ) throws -> Activity<HomecomingAttributes> {

        guard activitiesEnabled else { throw StartError.notAuthorized }
        guard activity == nil else { throw StartError.alreadyRunning }

        let attributes = HomecomingAttributes(
            travelerName: travelerName,
            destinationName: destinationName,
            departedAt: Date(),
            sessionID: sessionID,
            audience: audience,
            routeShape: routeShape
        )

        let state = HomecomingAttributes.ContentState(
            stage: .leaving,
            transport: transport,
            expectedArrival: expectedArrival,
            remainingMeters: totalMeters,
            totalMeters: totalMeters,
            detail: detail ?? "\(transport.title) 탑승",
            measuredAt: Date(),
            lat: coordinate?.latitude,
            lon: coordinate?.longitude,
            homeLat: home?.latitude,
            homeLon: home?.longitude,
            homeRadius: homeRadius,
            checkInDeadline: checkInDeadline
        )

        let content = ActivityContent(state: state, staleDate: state.staleDate)
        let activity: Activity<HomecomingAttributes>

        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: pushType)
        } catch where pushType != nil {
            // 푸시 자격이 없는 빌드(엔타이틀먼트 누락, 시뮬레이터 등)에서는 .token 요청이 실패한다.
            // 그렇다고 알림 자체를 포기할 이유는 없다. 로컬 갱신만으로 띄우고 계속 간다.
            HomecomingLog.activity.warning(
                "pushType=.token 실패, 로컬 갱신으로 대체: \(error.localizedDescription, privacy: .public)"
            )
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        }

        self.activity = activity
        observeContent(of: activity)
        HomecomingLog.activity.notice("액티비티 시작 id=\(activity.id, privacy: .public) pushType=\(String(describing: self.pushType), privacy: .public)")
        return activity
    }

    /// `activity` 를 새로 잡을 때마다 그 갱신 스트림을 새로 구독한다.
    ///
    /// `contentUpdates` 는 로컬 `update(...)` 든 서버 push 든 `content` 가
    /// 바뀔 때마다 새 값을 낸다 — 그래서 이 하나로 두 경로를 다 잡는다.
    private func observeContent(of activity: Activity<HomecomingAttributes>) {
        contentObservation?.cancel()
        currentState = activity.content.state
        contentObservation = Task { [weak self] in
            for await content in activity.contentUpdates {
                guard !Task.isCancelled else { return }
                self?.currentState = content.state
            }
        }
    }

    private func stopObservingContent() {
        contentObservation?.cancel()
        contentObservation = nil
        currentState = nil
    }

    // MARK: - 갱신

    /// 위치가 바뀔 때마다 호출. 남은 거리로 단계를 알아서 승격시킨다.
    /// **nil 은 "그대로 둔다" 는 뜻이다.**
    ///
    /// 경로로 도는 귀가에서는 남은거리·도착예정·수단·문구의 주인이 서버다. 서버가
    /// 경로를 따라 재고 지금 구간의 문구를 만들어 민다. 앱이 같은 자리에 자기 값을
    /// 밀어 넣으면 나중에 민 쪽이 이기는데, 앱이 든 값은 **출발 시점에 굳은 것**이라
    /// 집 앞에서도 "국회의사당역까지 5분" 이 뜬다(2026-08-14 실주행에서 실제로 그랬다).
    ///
    /// 그래서 앱은 자기가 진짜 아는 것만 넘기고 나머지는 nil 로 비운다.
    func update(
        remainingMeters: Int? = nil,
        expectedArrival: Date? = nil,
        transport: HomecomingAttributes.Transport? = nil,
        detail: String? = nil,
        arrivalRadius: Int = 60,
        anomaly: HomecomingAttributes.Anomaly? = nil,
        coordinate: CLLocationCoordinate2D? = nil,
        /// `coordinate` 를 **잰 시각**. 좌표와 짝이다 — 둘 다 이 기기의 GPS 가 원본이다.
        measuredAt: Date? = nil,
        home: CLLocationCoordinate2D? = nil,
        homeRadius: Int? = nil
    ) async {
        guard let activity else { return }

        let previous = activity.content.state
        let meters = remainingMeters ?? previous.remainingMeters
        let stage = Self.stage(
            forRemainingMeters: meters,
            previous: previous.stage,
            arrivalRadius: arrivalRadius
        )

        let state = HomecomingAttributes.ContentState(
            stage: stage,
            transport: transport ?? previous.transport,
            expectedArrival: expectedArrival ?? previous.expectedArrival,
            remainingMeters: max(0, meters),
            totalMeters: max(previous.totalMeters, meters),
            // **진행도는 서버만 아는 값이다.** 앱은 자기가 경로 위 어디인지 모른다 —
            // 경로 좌표열도, 어느 구간인지도 서버가 들고 있다. 그래서 여기서 만들 수
            // 없고, 옮겨 담아 다음 푸시까지 그 자리에 세운다.
            //
            // 안 옮기면 로컬 갱신 한 번에 지워지고, 노선도의 점과 지도의 색 분리가
            // 그 순간 옛 계산(`totalMeters - remainingMeters`)으로 되돌아간다 —
            // 이탈 중이면 점이 앞으로 튄다. 위 주석이 경고하는 그 함정이다.
            travelledMeters: previous.travelledMeters,
            detail: detail ?? previous.detail,
            // **앱이 모르는 값은 옮겨 담아야 "그대로 둔다" 가 된다.**
            //
            // 이 함수의 계약은 "nil 은 그대로 둔다" 인데, 구조체 필드를 아예 안 쓰면
            // nil 이 되어 **지운다**. 그래서 서버만 아는 값 셋이 로컬 갱신마다
            // 사라지고 있었다 — 이상 상황 한 번 올릴 때 지연 표기("10분 지연")가
            // 같이 지워졌다. `previous` 에서 그대로 옮긴다.
            delaySeconds: previous.delaySeconds,
            // **이건 서버만 아는 값이 아니다.** 좌표와 같은 규칙을 쓴다 — 새 자리를
            // 아는 호출부는 그 자리를 잰 시각을 함께 넘기고, 모르는 호출부만 옮겨 담는다.
            //
            // 옮겨 담기만 하던 동안 귀가자 폰에서 이런 일이 났다(2026-08-21 14:41 실주행):
            // 화면은 자기 GPS 로 그린 자리를 보여 주면서 "10분 전 위치" 라고 적었다.
            // 그 10분은 위치의 나이가 아니라 **서버 푸시가 마지막으로 닿은 뒤 흐른
            // 시간**이었다. 낡음 판정이 `measuredAt` 을 먼저 보기 때문이다
            // (`HomecomingViewParts.staleNote`). 이 기기는 픽스 시각을 정확히
            // 아는데도 남이 되돌려 준 값에 매여 있었다.
            //
            // **제자리 보고에서는 이 값이 늙는 것이 맞다.** 그때는 새 픽스가 없어
            // 들고 있던 옛 픽스를 다시 보내므로, 자리도 그 시각 것이다.
            measuredAt: measuredAt ?? previous.measuredAt,
            // 이것이 지워지면 지도의 이탈 한 줄이 사라져, 점과 색이 어긋난 이유를
            // 화면이 설명하지 못한다. `travelledMeters` 와 같은 이유다.
            estimateSource: previous.estimateSource,
            // **좌표도 옮겨 담는다.** 안 쓰면 nil 이 되어 지워지고, 가족 화면의
            // 지도가 로컬 갱신 한 번에 사라진다 — 위 주석이 경고하는 그 함정이다.
            // 새 자리를 아는 호출부는 넘기고, 모르는 호출부는 nil 로 두어 유지한다.
            lat: coordinate?.latitude ?? previous.lat,
            lon: coordinate?.longitude ?? previous.lon,
            homeLat: home?.latitude ?? previous.homeLat,
            homeLon: home?.longitude ?? previous.homeLon,
            homeRadius: homeRadius ?? previous.homeRadius,
            // 확인 마감은 여기서 건드리지 않는다. 잠금화면 버튼이 직접 갱신하는 값이라
            // 위치 갱신이 덮어쓰면 방금 누른 확인이 사라진다.
            checkInDeadline: previous.checkInDeadline,
            endReason: previous.endReason,
            anomaly: anomaly,
            // **다음 버스 도착도 서버만 아는 값이다.** 앱은 어느 정류장인지도,
            // 그 버스가 어디 있는지도 모른다.
            //
            // 안 옮기면 로컬 갱신 한 번에 지워진다. 2026-08-26 시뮬레이터 검증에서
            // 정확히 그랬다 — 서버가 `999 · 15:59 도착 · 2정류장 전` 을 보냈는데
            // 화면에는 아무것도 없었다. 위의 `travelledMeters`·`delaySeconds` 가
            // 같은 함정에 빠졌던 자리이고, 이 함수는 `ContentState` 를 처음부터
            // 다시 만들기 때문에 **필드를 안 쓰는 것이 곧 지우는 것**이다.
            //
            // 와이어에 필드를 더할 때 고쳐야 하는 자리가 셋이 아니라 넷이다
            // (`CodingKeys` · `init(from:)` · `encode(to:)` · 여기).
            busArrivalNo: previous.busArrivalNo,
            busArrivalAt: previous.busArrivalAt,
            busArrivalStops: previous.busArrivalStops,
            busArrivalMeasuredAt: previous.busArrivalMeasuredAt,
            // **서버만 아는 값이다.** 안 옮기면 로컬 갱신 한 번에 지워진다 —
            // 서버는 계속 보내는데 화면에서 사라진다.
            busArrivalThenNo: previous.busArrivalThenNo,
            busArrivalThenAt: previous.busArrivalThenAt,
            busArrivalThenStops: previous.busArrivalThenStops
        )

        let alert = Self.alert(for: state, previous: previous, name: activity.attributes.travelerName)

        await activity.update(
            ActivityContent(state: state, staleDate: state.staleDate),
            alertConfiguration: alert
        )
        HomecomingLog.activity.debug("갱신 stage=\(stage.rawValue, privacy: .public) 남은=\(state.remainingMeters)m")
    }

    /// 화면을 깨울 만한 변화인지 판단한다.
    ///
    /// 이동 중 갱신은 조용히 지나가야 한다. 매번 울리면 사람들은 알림을 꺼 버리고,
    /// 그러면 정말 울려야 할 때 아무도 못 본다.
    private static func alert(
        for state: HomecomingAttributes.ContentState,
        previous: HomecomingAttributes.ContentState,
        name: String
    ) -> AlertConfiguration? {

        // 새로 생긴 이상 상황이 최우선.
        // 지연·정지는 흔해서 화면을 깨우지 않고 조용히 반영만 한다.
        // 무응답·경로 이탈만 울린다 — 울리는 알림이 흔해지면 아무도 안 본다.
        if let anomaly = state.anomaly, anomaly != previous.anomaly, anomaly.isUrgent {
            return AlertConfiguration(
                title: LocalizedStringResource(stringLiteral: anomaly.shortLabel),
                body: LocalizedStringResource(stringLiteral: "\(name) · \(anomaly.title)"),
                sound: .default
            )
        }

        if state.stage == .nearby && previous.stage != .nearby {
            return AlertConfiguration(
                title: "곧 도착",
                body: LocalizedStringResource(stringLiteral: "\(name.이가) \(state.remainingDistanceText) 앞이에요"),
                sound: .default
            )
        }

        return nil
    }

    /// **서버가 방금 계산해 준 상태를 그대로 받는다.**
    ///
    /// 위치를 보고하면 그 응답에 지금 상태가 실려 온다. 그 값의 주인은 서버다 —
    /// 경로 위 어디인지, 남은거리가 얼마인지, 이탈했는지는 서버만 안다.
    ///
    /// **`update(...)` 와 다른 함수인 이유.** 그쪽은 "앱이 아는 것만 넘기고 나머지는
    /// 그대로 둔다" 는 계약이라 서버 값을 못 만든다. 이건 반대로 서버 값을 통째로
    /// 받아 앉히는 자리다. 둘을 한 함수로 합치면 nil 의 뜻이 두 개가 된다.
    ///
    /// **앱만 아는 둘은 지킨다.** 서버는 안심 확인도 이상 상황도 모른다
    /// (`homecoming_server.py` 에 `check_in` 도 `anomaly` 도 없다). 통째로 앉히면
    /// 방금 누른 확인이 사라지고 화면의 이상 표시가 꺼진다.
    ///
    /// 이게 있어야 귀가자 폰이 푸시를 기다리지 않는다. 예전에는 좌표만 자기가 쓰고
    /// 남은거리·진행도는 푸시로만 받아서, 푸시가 늦으면 한 화면 안에서 어긋났다 —
    /// 점은 지금 자리인데 남은거리는 몇 분 전 것이었다(2026-08-21 14:41 실주행).
    func adopt(_ incoming: HomecomingAttributes.ContentState) async {
        guard let activity else { return }
        let previous = activity.content.state

        var state = incoming
        state.checkInDeadline = previous.checkInDeadline
        state.anomaly = previous.anomaly

        // 값이 그대로면 밀지 않는다. 같은 값을 계속 밀면 아일랜드가 계속 펼쳐지고
        // 갱신 예산만 먹는다(`refreshAnomaly` 가 같은 이유로 그렇게 한다).
        guard state != previous else { return }

        await activity.update(ActivityContent(state: state, staleDate: state.staleDate))
        HomecomingLog.activity.debug(
            "서버 상태 반영 stage=\(state.stage.rawValue, privacy: .public) 남은=\(state.remainingMeters)m")
    }

    // MARK: - 안심 확인

    /// 앱 안에서 확인을 누른 경우. 잠금화면 버튼과 같은 구현을 탄다.
    func checkIn(interval: TimeInterval = HomecomingCheckIn.defaultInterval) async {
        guard let activity else { return }
        await HomecomingCheckIn.record(activityID: activity.id, interval: interval)
        HomecomingLog.activity.notice("안심 확인 기록")
    }

    // MARK: - 종료

    /// 도착 처리.
    ///
    /// `end(...)` 를 부르는 순간 다이나믹 아일랜드는 알림을 즉시 치운다.
    /// (잠금화면은 dismissalPolicy 만큼 남지만, 아일랜드는 그렇지 않다.)
    /// 그래서 바로 끝내지 않고 '도착' 상태로 잠깐 살려 둔다 —
    /// 기다리던 가족이 실제로 보게 되는 건 이 몇 초다.
    /// 도착 처리 — **도착 상태만 남기고 끝내지는 않는다.**
    ///
    /// 끝내는 일(`end`)은 서버가 한다. 이유는 아일랜드다. `end(...)` 를 부르는 순간
    /// 다이나믹 아일랜드는 **즉시** 치운다 — `dismissalPolicy` 는 잠금화면에만 듣는다.
    /// 그래서 아일랜드에 도착 화면을 5분 띄우려면 5분 동안 `end` 를 안 불러야 하는데,
    /// 도착은 대개 백그라운드에서 판정되고 `beginBackgroundTask` 어시션은 30초쯤이면
    /// 만료된다. **앱은 구조적으로 그 5분을 못 버틴다.**
    ///
    /// 서버는 iOS 에 안 잠긴다. 스레드에서 자다가 5분 뒤 `end` 를 쏘면 두 기기의
    /// 아일랜드와 잠금화면이 **동시에** 사라진다. 지금까지 앱과 서버가 각자 끝내서
    /// 아일랜드는 20초, 잠금화면은 그보다 길게 갈렸다.
    ///
    /// 서버가 침묵할 때는 `staleDate`(도착 + 10분)가 화면을 흐리게 만들고, 앱이
    /// 다음에 켜질 때 `reattach()` 가 끝난 액티비티를 치운다.
    func finish(coordinate: CLLocationCoordinate2D? = nil) async {
        guard let activity else { return }

        let previous = activity.content.state
        let state = HomecomingAttributes.ContentState(
            stage: .arrived,
            transport: previous.transport,
            expectedArrival: Date(),
            remainingMeters: 0,
            totalMeters: previous.totalMeters,
            // 그대로 옮긴다. 도착에서는 두 화면이 이 값을 안 본다 —
            // `stage.isFinished` 면 노선도의 점도 지도의 색 분리도 끝에 세운다.
            // 그래도 지우지 않는다: 지우는 것은 "그대로 둔다" 가 아니다.
            travelledMeters: previous.travelledMeters,
            detail: nil,
            measuredAt: Date(),
            // 도착해도 마지막 자리는 지우지 않는다. 서버가 `fixes` 를 지운 뒤에도
            // `last_lat` 을 들고 있는 것과 같은 이유다 — 가족이 보던 지도가
            // 도착하는 순간 빈칸이 되면 도착이 아니라 고장으로 읽힌다.
            //
            // **도착을 유발한 위치를 받아야 한다.** `previous` 만 쓰면 한 발 늦은
            // 자리가 남는다 — 도착 판정은 위치 갱신보다 먼저 일어나므로 `previous`
            // 는 그 직전 지점이다. 시뮬레이터에서 카드가 "도착했어요" 인데 지도의
            // 점은 집에서 2km 떨어진 곳에 있었다. **한 화면이 두 말을 하면 안 된다.**
            lat: coordinate?.latitude ?? previous.lat,
            lon: coordinate?.longitude ?? previous.lon,
            homeLat: previous.homeLat,
            homeLon: previous.homeLon,
            homeRadius: previous.homeRadius,
            endReason: .arrived
        )
        // **`staleDate` 를 켜 둔다.** 서버가 침묵해도 이 시각이 지나면 시스템이
        // 화면을 흐리게 만든다. 앱 코드가 한 줄도 안 돌아도 동작하는 유일한 장치다.
        let content = ActivityContent(state: state, staleDate: state.staleDate)

        // 도착은 대개 백그라운드에서 판정된다. 갱신 한 번을 보낼 동안은 깨어 있어야 한다.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "homecoming.arrival")
        defer { UIApplication.shared.endBackgroundTask(assertion) }

        await activity.update(
            content,
            alertConfiguration: AlertConfiguration(
                title: "도착",
                body: "\(activity.attributes.travelerName.이가) \(activity.attributes.destinationName)에 도착했어요",
                sound: .default
            )
        )
        HomecomingLog.activity.notice("도착 상태 표시 — 끝내는 것은 서버에 맡긴다")

        self.activity = nil
        stopObservingContent()
    }

    /// 도착 전에 사용자가 직접 끄는 경우.
    ///
    /// 그냥 지우지 않고 **왜 끝났는지**를 남긴다. 본인은 자기가 껐다는 걸 알지만
    /// 가족 화면에서는 도착과 구분이 안 되기 때문이다.
    /// (가족 기기 쪽은 서버가 같은 값을 실어 `end` 를 보낸다.)
    func cancel() async {
        guard let activity else { return }

        var state = activity.content.state
        state.endReason = .stopped

        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(30))
        )
        self.activity = nil
        stopObservingContent()
        HomecomingLog.activity.notice("액티비티 중지 (공유 끔)")
    }

    /// 앱이 재시작됐을 때 이미 떠 있는 액티비티를 다시 붙잡는다.
    ///
    /// 끝난 액티비티는 잠금화면에서 사라지기 전까지 목록에 남아 있다.
    /// 그걸 붙잡으면 다음 귀가가 "이미 진행 중"으로 막히므로 살아 있는 것만 고른다.
    func reattach() {
        let all = Activity<HomecomingAttributes>.activities
        for item in all {
            HomecomingLog.activity.notice(
                """
                살아 있는 액티비티 id=\(item.id, privacy: .public) \
                대상=\(item.attributes.audience.rawValue, privacy: .public) \
                이름=\(item.attributes.travelerName, privacy: .public) \
                상태=\(String(describing: item.activityState), privacy: .public) \
                단계=\(item.content.state.stage.rawValue, privacy: .public)
                """
            )
        }
        if all.isEmpty {
            HomecomingLog.activity.notice("살아 있는 액티비티 없음")
        }

        // **가족(watcher) 액티비티는 붙잡지 않는다.**
        //
        // 그건 서버가 밀어 주는 화면이다. 이 기기가 붙잡으면 위치 갱신이 돌 때마다
        // 서버가 보낸 값을 자기 계산으로 덮어써 버린다. 가족 폰에 등록된 집이 있으면
        // 남의 귀가 진행률 자리에 자기 집까지의 거리가 들어가는 식으로 조용히 망가진다.
        activity = all.first {
            $0.attributes.audience == .traveler
                && ($0.activityState == .active || $0.activityState == .stale)
        }

        if let activity {
            observeContent(of: activity)
        } else {
            stopObservingContent()
        }

        // **끝났는데 안 치워진 것을 치운다.**
        //
        // 도착 카드를 끝내는 일은 서버가 맡는다(`finish()` 참고). 서버가 죽어 있거나
        // 폰이 그때 신호를 못 받았으면 `end` 가 영영 안 온다. 그러면 다 끝난 귀가의
        // 카드가 잠금화면에 계속 남는다 — 다음 귀가와 겹쳐 보이기까지 한다.
        //
        // 앱이 켜지는 순간이 그걸 알아챌 수 있는 자리다.
        let orphans = all.filter { $0.content.state.endReason != nil }
        guard !orphans.isEmpty else { return }
        Task {
            for item in orphans {
                await item.end(nil, dismissalPolicy: .immediate)
                HomecomingLog.activity.notice("끝난 액티비티 정리 id=\(item.id, privacy: .public)")
            }
        }
    }

    // MARK: - 규칙

    /// 남은 거리로 단계를 결정한다. 한 번 올라간 단계는 되돌리지 않는다
    /// (GPS 가 튀어서 '곧 도착' 이 '이동 중' 으로 내려가면 가족이 혼란스럽다).
    ///
    /// `arrivalRadius` 는 등록된 집의 도착 반경을 그대로 받는다.
    /// 아파트 단지와 단독주택은 '도착'의 크기가 다르다.
    static func stage(
        forRemainingMeters meters: Int,
        previous: HomecomingAttributes.Stage,
        arrivalRadius: Int = 60
    ) -> HomecomingAttributes.Stage {
        let nearbyRadius = max(arrivalRadius * 5, 800)
        let candidate: HomecomingAttributes.Stage
        switch meters {
        case ..<arrivalRadius: candidate = .arrived
        case ..<nearbyRadius:  candidate = .nearby
        default:               candidate = .moving
        }
        return order(candidate) >= order(previous) ? candidate : previous
    }

    private static func order(_ stage: HomecomingAttributes.Stage) -> Int {
        switch stage {
        case .leaving: return 0
        case .moving:  return 1
        case .nearby:  return 2
        case .arrived: return 3
        }
    }

}
