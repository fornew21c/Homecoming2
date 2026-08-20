import ActivityKit
import Foundation

/// API 명세서에 넣을 페이로드를 **실제 타입에서** 뽑아낸다.
///
/// 손으로 적은 스키마는 코드가 바뀌면 조용히 낡는다.
/// 여기서 찍어낸 것을 문서에 옮기면 적어도 옮긴 시점에는 반드시 맞는다.
///
///     xcrun simctl launch <udid> com.kona.homecoming2 -homecomingPrintContract
enum ContractDump {

    static func run() {
        let attributes = HomecomingAttributes(
            travelerName: "엄마",
            destinationName: "집",
            departedAt: Date(timeIntervalSince1970: 1_786_724_640),   // 2026-08-13 16:24:00Z
            audience: .watcher
        )

        let moving = HomecomingAttributes.ContentState(
            stage: .moving,
            transport: .subway,
            expectedArrival: Date(timeIntervalSince1970: 1_786_735_440),   // 19:24:00Z
            remainingMeters: 4_200,
            totalMeters: 11_000,
            // 노선도의 점과 지도의 색 분리가 함께 쓰는 값. 경로 위에서는
            // `totalMeters - remainingMeters` 와 대개 비슷하다.
            travelledMeters: 6_800,
            detail: "2호선 · 3정거장 남음",
            measuredAt: Date(timeIntervalSince1970: 1_786_734_600),        // 19:10:00Z
            estimateSource: "route",
            checkInDeadline: Date(timeIntervalSince1970: 1_786_726_440),   // 16:54:00Z
            anomaly: nil
        )

        let delayed = HomecomingAttributes.ContentState(
            stage: .nearby,
            transport: .walk,
            expectedArrival: Date(timeIntervalSince1970: 1_786_736_400),
            remainingMeters: 240,
            totalMeters: 11_000,
            // **여기서 두 값이 갈라진다.** `estimateSource` 가 `offRoute` 라 남은거리는
            // 집까지 **직선거리**(240m)다. 되짚으면 10,760m 로 "거의 다 왔다" 가 되는데,
            // 실제로 경로 위에서 지나온 것은 8,600m 에서 멈춰 있다. 이 표본이
            // 지키는 것이 그 차이다 — 노선도가 되짚기로 돌아가면 점이 앞으로 튄다.
            travelledMeters: 8_600,
            detail: "아파트 정문 앞",
            // 지연 배지가 실제로 실리는지 여기서 확인한다. 이 키가 빠져 있어
            // 2026-08-18 실주행 내내 배지가 뜨지 않았다.
            delaySeconds: 480,
            measuredAt: Date(timeIntervalSince1970: 1_786_736_040),
            estimateSource: "offRoute",
            checkInDeadline: Date(timeIntervalSince1970: 1_786_726_440),
            anomaly: .delayed
        )

        let arrived = HomecomingAttributes.ContentState(
            stage: .arrived,
            transport: .walk,
            expectedArrival: Date(timeIntervalSince1970: 1_786_736_700),
            remainingMeters: 0,
            totalMeters: 11_000,
            // 도착하면 서버가 경로 전체 길이를 보낸다. `route_progress` 는 끝까지
            // 가지 않으므로(도착은 거리로 판정한다) 서버가 그 자리에서 채운다.
            travelledMeters: 11_000,
            detail: nil,
            measuredAt: Date(timeIntervalSince1970: 1_786_736_700),
            estimateSource: "route",
            checkInDeadline: nil,
            anomaly: nil
        )

        emit("start", [
            "aps": [
                "timestamp": 1_786_724_640,
                "event": "start",
                "content-state": json(moving),
                "attributes-type": "HomecomingAttributes",
                "attributes": json(attributes),
                "alert": [
                    "title": "귀가 시작",
                    "body": "엄마가 집으로 출발했어요"
                ]
            ]
        ])

        emit("update", [
            "aps": [
                "timestamp": 1_786_726_500,
                "event": "update",
                "content-state": json(delayed),
                "alert": [
                    "title": "지연",
                    "body": "엄마 · 예정보다 늦어요"
                ]
            ]
        ])

        emit("end", [
            "aps": [
                "timestamp": 1_786_736_700,
                "event": "end",
                "content-state": json(arrived),
                "dismissal-date": 1_786_736_760
            ]
        ])

        emit("enum 값", [
            "stage": HomecomingAttributes.Stage.allCases.map(\.rawValue),
            "transport": HomecomingAttributes.Transport.allCases.map(\.rawValue),
            "anomaly": HomecomingAttributes.Anomaly.allCases.map(\.rawValue),
            "audience": HomecomingAttributes.Audience.allCases.map(\.rawValue),
            "endReason": HomecomingAttributes.EndReason.allCases.map(\.rawValue)
        ])

        // 노선도 점 위치. 경계값을 표로 찍어 눈으로 확인한다.
        //
        //     xcrun simctl launch <udid> com.kona.homecoming2 -homecomingPrintContract
        //
        // 시험 타겟이 없으므로 이 표가 회귀 시험이다. 값이 바뀌면 여기서 보인다.
        // `print` 가 아니라 `emit()` 을 쓴다 — 위 emit() 주석대로, print 는
        // 콘솔에만 남고 simctl 로 못 뽑는다.
        //
        // 정류장 거리는 `Tools/routes/commute-sample.json` 에 저장된 `meters` 값을
        // 손으로 옮긴 예시다. 서버 `route_stops()` 는 좌표열로 다시 재므로
        // (`leg_length()`) 실제 `/route/{id}` 응답과 1m 안팎 어긋날 수 있다
        // (버스 구간 5357 대 5356, 총합 28358 대 28357). 이 표는 자기 값으로
        // 자기를 검증하니 `position()` 확인 목적에는 문제없다.
        let shape = HomecomingAttributes.RouteShape(stops: [
            .init(name: "출발역.은행앞", mode: "walk",   meters: 445,    seconds: 360,  waitSeconds: 180),
            .init(name: "환승로터리",             mode: "bus",    meters: 5_357,  seconds: 540,  waitSeconds: 0),
            .init(name: "서강대역",               mode: "walk",   meters: 664,    seconds: 420,  waitSeconds: 240),
            .init(name: "풍산역",                 mode: "subway", meters: 18_683, seconds: 1_860, waitSeconds: 0),
            .init(name: "풍산역 정류장",           mode: "walk",   meters: 78,     seconds: 360,  waitSeconds: 120),
            .init(name: "아파트단지",          mode: "bus",    meters: 2_950,  seconds: 600,  waitSeconds: 0),
            .init(name: "집",                    mode: "walk",   meters: 181,    seconds: 180,  waitSeconds: 0),
        ])
        let total = shape.stops.reduce(0) { $0 + $1.meters }

        let positions = [0, 1, 444, 445, 446, 6_000, total - 1, total, total + 5_000, -100].map { travelled -> String in
            let at = shape.position(travelled: travelled)
            let name = shape.stops[at.index].name
            return String(format: "%8d m → [%d] %@ %.3f", travelled, at.index, name, at.fraction)
        }

        emit("노선도 점 위치", ["totalMeters": total, "positions": positions])
    }

    /// 지금 이 기기에 살아 있는 액티비티를 콘솔로 찍는다.
    ///
    /// 서버가 push-to-start 로 띄운 것도 여기 잡힌다 —
    /// 원격 시작이 실제로 먹혔는지 확인하는 가장 확실한 방법이다.
    ///
    ///     xcrun devicectl device process launch --device <id> --console \
    ///       com.kona.homecoming2 -homecomingListActivities
    static func listActivities() {
        print("[귀가마중] push-to-start: \(HomecomingPushRegistrar.storedPushToStartToken ?? "없음")")
        print("[귀가마중] activity-token: \(HomecomingPushRegistrar.storedActivityToken ?? "없음")")

        let all = Activity<HomecomingAttributes>.activities
        guard !all.isEmpty else {
            print("[귀가마중] 살아 있는 액티비티 없음")
            return
        }
        for item in all {
            print(
                "[귀가마중] 액티비티 id=\(item.id)"
                + " 대상=\(item.attributes.audience.rawValue)"
                + " 이름=\(item.attributes.travelerName)"
                + " 상태=\(item.activityState)"
                + " 단계=\(item.content.state.stage.rawValue)"
                + " 도착예정=\(HomecomingWire.string(from: item.content.state.expectedArrival))"
                + " 남은=\(item.content.state.remainingMeters)m"
                + " detail=\(item.content.state.detail ?? "-")"
            )
        }
    }

    /// 살아 있는 액티비티를 '공유 중지' 로 끝낸다. 표시 확인용.
    static func stopSharing() async {
        guard let activity = Activity<HomecomingAttributes>.activities.first else {
            print("[귀가마중] 끝낼 액티비티가 없음")
            return
        }
        var state = activity.content.state
        state.endReason = .stopped
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(120))
        )
        print("[귀가마중] 공유 중지로 종료 id=\(activity.id)")
    }

    // MARK: - 보조

    private static func json<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }
        return object
    }

    private static func emit(_ label: String, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else { return }

        // print 는 콘솔에만 남는다. 로그로 내보내야 simctl 로 뽑을 수 있다.
        HomecomingLog.push.notice("―― \(label, privacy: .public) ――\n\(text, privacy: .public)")
    }
}
