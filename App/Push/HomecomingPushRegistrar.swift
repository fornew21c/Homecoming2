import ActivityKit
import Foundation
import Observation
import UIKit

/// 세 종류의 토큰을 붙잡아 서버에 올린다.
///
/// 1. **APNs 기기 토큰** — 일반 푸시.
/// 2. **push-to-start 토큰** — 서버가 액티비티를 원격으로 *시작*시킨다. 앱이 떠 있지 않아도 된다.
///    가족 기기에 귀가 알림을 띄우는 건 이 토큰 하나로 갈린다.
/// 3. **액티비티 갱신 토큰** — 이미 뜬 액티비티에 새 상태를 밀어 넣는다. 액티비티마다 따로 발급된다.
///
/// 셋 다 언제든 재발급될 수 있어서, 한 번 받고 끝이 아니라 스트림을 계속 듣고 있어야 한다.
@MainActor
@Observable
final class HomecomingPushRegistrar {

    private let backend: HomecomingBackend

    private(set) var deviceToken: String?
    private(set) var pushToStartToken: String?
    private(set) var activityTokens: [String: String] = [:]
    private(set) var lastError: String?

    private var pushToStartTask: Task<Void, Never>?
    private var activityDiscoveryTask: Task<Void, Never>?
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]

    /// 액티비티 갱신 토큰을 서버에 올릴 때 같이 보낼 이름.
    var travelerName = "아빠"

    /// 토큰 스트림은 값이 **바뀔 때만** 흐른다. 앱을 다시 켰다고 또 주지 않는다.
    /// 서버 등록이 한 번 실패하면 다음 기회가 언제일지 모르므로 마지막 값을 들고 있는다.
    nonisolated private static let storedStartTokenKey = "homecoming.pushToStartToken"
    nonisolated private static let storedActivityTokenKey = "homecoming.activityToken"

    nonisolated static var storedPushToStartToken: String? {
        UserDefaults.standard.string(forKey: storedStartTokenKey)
    }

    nonisolated static var storedActivityToken: String? {
        UserDefaults.standard.string(forKey: storedActivityTokenKey)
    }

    init(backend: HomecomingBackend) {
        self.backend = backend
        pushToStartToken = Self.storedPushToStartToken
    }

    // MARK: - 시작

    /// 앱 기동 직후 한 번 부른다.
    func start() {
        UIApplication.shared.registerForRemoteNotifications()
        resendStoredTokens()
        observePushToStartToken()
        observeActivities()
    }

    /// 저장해 둔 토큰을 다시 올린다.
    ///
    /// 스트림은 토큰이 **바뀔 때만** 흐른다. 앱을 다시 켰다고 또 주지 않는다.
    /// 그래서 서버가 토큰을 잃으면(새 배포, DB 복구, 등록 요청 실패)
    /// 그 기기는 다음 재설치 때까지 영영 알림을 못 받는다.
    /// 등록은 멱등이므로 매번 올려도 문제가 없다.
    private func resendStoredTokens() {
        if let hex = Self.storedPushToStartToken, let token = Data(hexString: hex) {
            upload { try await $0.register(pushToStartToken: token) }
        }
    }

    // MARK: - APNs 기기 토큰 (AppDelegate 가 넘겨준다)

    func handle(deviceToken token: Data) {
        deviceToken = token.hexString
        upload { try await $0.register(deviceToken: token) }
    }

    func handleRegistrationFailure(_ error: Error) {
        lastError = "원격 알림 등록 실패: \(error.localizedDescription)"
    }

    // MARK: - push-to-start 토큰

    private func observePushToStartToken() {
        pushToStartTask?.cancel()
        pushToStartTask = Task { [weak self] in
            for await token in Activity<HomecomingAttributes>.pushToStartTokenUpdates {
                guard let self, !Task.isCancelled else { return }
                self.pushToStartToken = token.hexString
                UserDefaults.standard.set(token.hexString, forKey: Self.storedStartTokenKey)
                self.upload { try await $0.register(pushToStartToken: token) }
            }
        }
    }

    // MARK: - 액티비티 갱신 토큰

    /// 우리가 직접 시작한 액티비티든, 서버가 push-to-start 로 띄운 액티비티든
    /// 모두 이 스트림을 통해 들어온다. 그래서 시작 경로마다 따로 붙일 필요가 없다.
    private func observeActivities() {
        activityDiscoveryTask?.cancel()
        activityDiscoveryTask = Task { [weak self] in
            guard let self else { return }

            // 앱이 재시작된 경우 이미 떠 있는 것들부터.
            for activity in Activity<HomecomingAttributes>.activities {
                self.observe(activity)
            }

            for await activity in Activity<HomecomingAttributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                self.observe(activity)
            }
        }
    }

    func observe(_ activity: Activity<HomecomingAttributes>) {
        let id = activity.id
        guard tokenTasks[id] == nil else { return }

        tokenTasks[id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self, !Task.isCancelled else { return }
                self.activityTokens[id] = token.hexString
                UserDefaults.standard.set(token.hexString, forKey: Self.storedActivityTokenKey)
                let sessionID = activity.attributes.sessionID
                self.upload { try await $0.register(activityID: id, updateToken: token, sessionID: sessionID) }
            }
        }

        // 액티비티가 끝나면 서버가 죽은 토큰에 계속 쏘지 않도록 정리한다.
        stateTasks[id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                guard state == .dismissed || state == .ended else { continue }
                self.forget(id)
                self.upload { try await $0.unregister(activityID: id) }
                return
            }
        }
    }

    private func forget(_ id: String) {
        tokenTasks[id]?.cancel()
        tokenTasks[id] = nil
        stateTasks[id]?.cancel()
        stateTasks[id] = nil
        activityTokens[id] = nil
    }

    // MARK: - 보조

    /// 서버 업로드는 실패해도 앱 흐름을 막지 않는다.
    /// 토큰은 스트림에서 다시 흘러나오므로 다음 기회에 또 올라간다.
    private func upload(_ work: @escaping @Sendable (HomecomingBackend) async throws -> Void) {
        let backend = self.backend
        Task { [weak self] in
            do {
                try await work(backend)
            } catch {
                self?.lastError = "토큰 등록 실패: \(error.localizedDescription)"
            }
        }
    }
}
