import ActivityKit
import Foundation
import Observation

/// 내가 지켜보는 사람들의 현재 상태.
///
/// 별도의 API 를 부르지 않는다. 서버가 이미 이 기기에 Live Activity 를 띄워 뒀고,
/// 그 안에 필요한 값이 다 들어 있다. 앱은 그걸 그대로 읽어 큰 화면으로 보여 줄 뿐이다.
///
/// **가족 기기는 아무것도 계산하지 않는다** 는 원칙이 여기서도 유지된다.
@MainActor
@Observable
final class WatchingStore {

    struct Entry: Identifiable {
        let id: String
        let attributes: HomecomingAttributes
        var state: HomecomingAttributes.ContentState
        var isFinished: Bool

        /// 이 값을 **받은** 때. `nil` 이면 "언제 것인지 모른다".
        ///
        /// 갱신 푸시는 위치 보고가 올 때 나간다. 그러니 이게 곧 마지막으로 위치가
        /// 확인된 때다. `ContentState` 에 시각을 넣지 않으려고 이렇게 한다 —
        /// 갱신값을 안 건드리는 것이 이 설계의 핵심이다.
        ///
        /// 이미 돌고 있던 액티비티를 **부트스트랩**으로 주워 담을 때(콜드 런치,
        /// 또는 iOS 가 백그라운드에서 앱을 밀어낸 뒤 다시 열 때)는 nil 이다.
        /// 앱을 연 시각은 위치가 확인된 시각이 아니다 — 모르는 걸 아는 척하면
        /// 귀가자 신호가 끊긴 상황이 방금 확인된 것처럼 보인다.
        var receivedAt: Date?
    }

    private(set) var entries: [Entry] = []

    private var discoveryTask: Task<Void, Never>?
    private var contentTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]

    func start() {
        guard discoveryTask == nil else { return }

        // 이미 돌고 있던 액티비티를 줍는 부트스트랩이다 — 콜드 런치뿐 아니라
        // iOS 가 백그라운드 앱을 메모리에서 밀어낸 뒤 다시 열 때도 매번 여기를
        // 탄다(이 화면을 여는 가장 흔한 경로가 바로 이거다). 이 시점엔 이
        // 값이 "언제 것"인지 알 길이 없으므로 receivedAt 은 nil 이다.
        for activity in Activity<HomecomingAttributes>.activities {
            adopt(activity, receivedAt: nil)
        }

        discoveryTask = Task { [weak self] in
            for await activity in Activity<HomecomingAttributes>.activityUpdates {
                guard let self, !Task.isCancelled else { return }
                // 앱이 떠 있는 동안 막 시작한 액티비티다. 지금이 곧 처음 받은 때다.
                self.adopt(activity, receivedAt: Date())
            }
        }
    }

    // MARK: - 내부

    /// 가족용 액티비티만 담는다. 내 귀가는 아래쪽 '내 귀가' 영역이 따로 보여 준다.
    private func adopt(_ activity: Activity<HomecomingAttributes>, receivedAt: Date?) {
        guard activity.attributes.audience == .watcher else { return }
        guard contentTasks[activity.id] == nil else { return }

        upsert(activity.id, attributes: activity.attributes, state: activity.content.state, receivedAt: receivedAt)

        contentTasks[activity.id] = Task { [weak self] in
            // `contentUpdates` 는 구독하자마자 지금 값을 한 번 그대로 다시
            // 흘려 보낸다(재생) — 바로 위 upsert 로 이미 반영한 스냅샷과
            // 같은 값이다. 이걸 "새로 받았다"고 치면 부트스트랩에서 넣은
            // nil 을 곧바로 덮어써서 끊긴 상태를 감춰 버린다. 그래서 첫
            // 방출은 건너뛰고, 그 다음부터 오는 값만 진짜 새 갱신으로 친다.
            var isFirst = true
            for await content in activity.contentUpdates {
                guard let self, !Task.isCancelled else { return }
                if isFirst {
                    isFirst = false
                    continue
                }
                self.upsert(activity.id, attributes: activity.attributes, state: content.state, receivedAt: Date())
            }
        }

        stateTasks[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }

                // `.ended` 에서 지우면 안 된다. 잠금화면에는 남아 있는데 앱에서만
                // 사라지면, 가족은 왜 조용해졌는지 볼 기회를 잃는다.
                // 시스템이 완전히 걷어낼 때(`.dismissed`)까지 같이 보여 준다.
                guard state == .dismissed else { continue }
                self.drop(activity.id)
                return
            }
        }
    }

    private func upsert(
        _ id: String,
        attributes: HomecomingAttributes,
        state: HomecomingAttributes.ContentState,
        receivedAt: Date?
    ) {
        // receivedAt 은 부르는 쪽이 정한다 — 부트스트랩(언제 것인지 모름)인지
        // 진짜 새 갱신(지금 막 받음)인지는 호출부(adopt, contentUpdates 루프)
        // 만 안다. `activityStateUpdates` 루프는 upsert 를 부르지 않는다 —
        // 액티비티 종료 신호일 뿐 새 위치가 아니라서, 여기서 시각을 밀면
        // 끊긴 상황을 안 끊긴 것처럼 보이게 만든다.
        let entry = Entry(
            id: id,
            attributes: attributes,
            state: state,
            isFinished: state.stage.isFinished,
            receivedAt: receivedAt
        )
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private func drop(_ id: String) {
        contentTasks[id]?.cancel()
        contentTasks[id] = nil
        stateTasks[id]?.cancel()
        stateTasks[id] = nil
        entries.removeAll { $0.id == id }
    }
}
