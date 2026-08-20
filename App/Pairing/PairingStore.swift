import Foundation
import Observation

/// 페어링 상태를 화면에 들고 있는다.
///
/// 연결은 서버에만 존재한다. 기기는 그 사본을 보여 줄 뿐이라, 화면을 열 때마다 다시 읽는다.
@MainActor
@Observable
final class PairingStore {

    private let client: PairingClient

    /// 서버가 붙어 있는지. 없으면 페어링 자체가 불가능하다.
    let isAvailable: Bool

    private(set) var invite: PairInvite?
    private(set) var watchers: [PairMember] = []
    private(set) var watching: [PairMember] = []
    private(set) var isWorking = false
    private(set) var lastError: String?

    /// 가족이 코드를 입력할 때 함께 보내는 이름. 귀가자 화면에 이 이름으로 뜬다.
    var myName: String {
        didSet { UserDefaults.standard.set(myName, forKey: Self.myNameKey) }
    }

    private static let myNameKey = "homecoming.myName"

    init(client: PairingClient, isAvailable: Bool) {
        self.client = client
        self.isAvailable = isAvailable
        self.myName = UserDefaults.standard.string(forKey: Self.myNameKey) ?? "가족"
    }

    // MARK: - 읽기

    func refresh() async {
        guard isAvailable else { return }
        do {
            async let mine = client.watchers()
            async let theirs = client.watching()
            watchers = try await mine
            watching = try await theirs
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 귀가자

    /// 초대 코드를 만든다. 이 코드를 가족에게 건네면 연결된다.
    func createInvite(travelerName: String) async {
        guard isAvailable else {
            lastError = "서버가 연결되어 있지 않습니다."
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            invite = try await client.invite(travelerName: travelerName)
            lastError = nil
            HomecomingLog.push.notice("초대 코드 발급")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 가족

    /// 받은 코드를 입력해 연결한다.
    @discardableResult
    func accept(code: String) async -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard isAvailable else {
            lastError = "서버가 연결되어 있지 않습니다."
            return false
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let link = try await client.accept(code: trimmed, myName: myName)
            lastError = nil
            HomecomingLog.push.notice("페어링 완료 상대=\(link.travelerName, privacy: .public)")
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - 해제

    /// 양쪽 다 자기 쪽에서 끊을 수 있다. 귀가자만 끊을 수 있게 하면
    /// 가족이 원치 않는 연결에 묶이고, 가족만 끊을 수 있게 하면 귀가자가 통제를 잃는다.
    func unlink(_ member: PairMember) async {
        isWorking = true
        defer { isWorking = false }

        do {
            try await client.unlink(accountID: member.accountID)
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
