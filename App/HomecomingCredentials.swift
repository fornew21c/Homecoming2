import Foundation
import Security

/// 이 기기가 서버에 자기를 밝히는 수단.
///
/// 서버는 예전에 `X-Account-Id` 헤더에 적힌 걸 그대로 믿었다. 헤더 한 줄만 바꾸면
/// 남의 실시간 위치를 읽고 남의 세션을 끝낼 수 있었다. 위치 공유 앱에서 그건 구멍이다.
///
/// 이제 기기 등록 때 서버가 계정 id 와 비밀 토큰을 발급하고, 이후 모든 요청이
/// `Authorization: Bearer <token>` 을 붙인다.
///
/// **토큰은 키체인에 둔다. UserDefaults 는 안 된다** — 실기기에서
/// `devicectl device copy` 로 UserDefaults 를 그대로 꺼내 봤다. 비밀을 거기 두면
/// 기기를 한 번 만질 수 있는 사람이 그대로 읽는다.
///
/// **앱을 지워도 키체인 항목은 남는다.** iOS 는 앱을 삭제해도 키체인을 지우지 않는다.
/// 실기기에서 지웠다 다시 깔아 보니 같은 계정으로 돌아왔다. 그래서 재설치해도
/// 가족 페어링이 유지된다 — 처음에는 반대로 알고 문서에도 그렇게 적어 뒀었다.
///
/// 계정을 정말로 버리려면 기기를 초기화하거나 `-homecomingResetIdentity` 를 쓴다.
struct HomecomingCredentials: Sendable, Equatable {
    let accountID: String
    let token: String
}

// MARK: - 공유 상자

/// 토큰을 담아 통신 계층에 나눠 주는 상자.
///
/// 통신 계층(세션 보고·페어링·경로·푸시)은 앱이 켜질 때 동기로 만들어지는데
/// 기기 등록은 비동기다. 그래서 계층마다 토큰을 복사해 넣지 않고 이 상자를
/// 나눠 준다 — 등록이 끝나면 상자만 채우면 되고, 이미 만들어진 계층이 그대로 쓴다.
///
/// 토큰이 아직 없으면 요청에 헤더가 안 붙고 서버가 401 을 준다. 등록이 끝나기 전에
/// 나간 요청이 조용히 남의 계정으로 처리되는 것보다 그게 낫다.
final class HomecomingAuth: @unchecked Sendable {

    private let lock = NSLock()
    private var credentials: HomecomingCredentials?

    init(_ credentials: HomecomingCredentials? = nil) {
        self.credentials = credentials
    }

    var current: HomecomingCredentials? {
        lock.lock(); defer { lock.unlock() }
        return credentials
    }

    /// 이 기기의 계정 id. 아직 등록 전이면 nil.
    var accountID: String? { current?.accountID }

    func set(_ credentials: HomecomingCredentials?) {
        lock.lock(); defer { lock.unlock() }
        self.credentials = credentials
    }

    /// 요청에 인증 헤더를 붙인다. 토큰이 없으면 아무것도 붙이지 않는다.
    func authorize(_ request: inout URLRequest) {
        guard let token = current?.token else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - 등록과 401 회복

    /// 자격이 없으면 서버에서 받아 온다. 이미 있으면 아무것도 하지 않는다.
    ///
    /// **등록은 이 한 곳에서만 일어난다.** 앱이 켜질 때 부르는 것도, 401 을 받고
    /// 다시 받는 것도 여기를 지난다. 그러지 않으면 둘이 경주한다 — 실제로 실기기
    /// 에서 1초 사이에 계정이 두 개 만들어졌다. 앱이 뜨자마자 푸시 토큰 등록이
    /// 나갔는데 그때는 아직 자격이 없어 401 을 받았고, 회복 경로가 그걸 "토큰이
    /// 죽었다" 로 보고 최초 등록과 별개로 계정을 하나 더 만들었다.
    @discardableResult
    func ensureRegistered(baseURL: URL, session: URLSession = .shared) async -> Bool {
        if current != nil { return true }

        guard await gate.begin() else {
            // 다른 쪽이 등록 중이다. 그게 끝날 때까지 기다렸다가 그 결과를 쓴다.
            await gate.wait()
            return current != nil
        }
        defer { Task { await gate.finish() } }

        if current != nil { return true }   // 기다리는 사이 채워졌을 수 있다

        do {
            let issued = try await HomecomingCredentials.loadOrRegister(baseURL: baseURL, session: session)
            set(issued)
            return true
        } catch {
            HomecomingLog.push.error("기기 등록 실패: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 서버가 이 토큰을 모른다고 할 때 자격을 버리고 새로 받는다.
    ///
    /// **이게 없으면 앱이 영구히 멈춘다.** 토큰이 살아 있는 동안은 아무 문제가 없다가,
    /// 서버 쪽에서 토큰이 사라지는 순간(DB 초기화, 토큰 저장 방식 변경, 계정 정리)
    /// 앱은 401 만 받으면서 그 토큰을 영원히 다시 보낸다. 귀가는 시작되지 않고
    /// 가족은 아무것도 못 보는데, 화면에는 서버 오류만 뜬다.
    ///
    /// 재등록은 **새 계정**이다. 페어링은 다시 맺어야 한다 — 되찾을 방법이 없다.
    /// 그래서 조용히 하지 않고 로그에 남긴다.
    func recoverFromUnauthorized(baseURL: URL, session: URLSession = .shared) async -> Bool {
        let stale = current?.token
        guard await gate.begin() else {
            // 다른 쪽이 이미 받아 오는 중이다. 그 결과를 기다린다.
            await gate.wait()
            return current?.token != stale && current != nil
        }
        defer { Task { await gate.finish() } }

        // 기다리는 사이 다른 쪽이 새 토큰을 받아 왔으면 그걸 쓴다.
        if let now = current?.token, now != stale { return true }

        HomecomingCredentialStore.clear()
        set(nil)
        do {
            let issued = try await HomecomingCredentials.loadOrRegister(baseURL: baseURL, session: session)
            set(issued)
            HomecomingLog.push.notice(
                "토큰이 거절되어 새 계정으로 등록했습니다: \(issued.accountID, privacy: .public). 가족 연결을 다시 맺어야 합니다."
            )
            return true
        } catch {
            HomecomingLog.push.error("재등록 실패: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 인증을 붙여 보내고, 401 이면 자격을 새로 받아 **한 번 더** 보낸다.
    ///
    /// 통신 계층 넷이 각자 `authorize` 를 부르고 있었는데, 그중 한 곳
    /// (`RemoteHomecomingBackend`)에서 그 한 줄이 빠져 있었다. 푸시 토큰 등록이
    /// 전부 401 로 떨어졌고, 증상은 "가족 카드가 아예 안 뜬다" 였다 — 헤더 한 줄이
    /// 빠진 것과 증상이 전혀 닮지 않아서 실기기 검증에서 한참 헤맸다.
    ///
    /// 그래서 붙이는 자리를 하나로 모았다. 여기를 지나지 않는 요청이 없으면
    /// 빠뜨릴 자리도 없다.
    ///
    /// - Parameter build: 요청을 만든다. 재시도 때 다시 불린다.
    func send(
        baseURL: URL,
        session: URLSession = .shared,
        build: () throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {

        func once() async throws -> (Data, HTTPURLResponse) {
            var request = try build()
            authorize(&request)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HomecomingRegistrationError.badResponse(-1)
            }
            return (data, http)
        }

        // 자격이 없으면 보내지 않는다. 헤더 없이 보내면 401 이 오고, 그걸 회복
        // 경로가 "토큰이 죽었다" 로 오해해서 계정을 하나 더 만든다.
        if current == nil {
            await ensureRegistered(baseURL: baseURL, session: session)
        }

        let (data, http) = try await once()
        guard http.statusCode == 401 else { return (data, http) }

        // 서버가 이 토큰을 모른다. 새로 받아서 한 번만 더 시도한다.
        guard await recoverFromUnauthorized(baseURL: baseURL, session: session) else {
            return (data, http)
        }
        return try await once()
    }

    private let gate = RegistrationGate()

    /// 등록이 한 번만 돌게 막는 문.
    ///
    /// 막기만 해서는 부족하다 — 밀린 쪽이 그냥 돌아가면 자격이 아직 없는 채로
    /// 요청을 보낸다. 그래서 **기다릴 수 있어야** 한다.
    private actor RegistrationGate {
        private var running = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func begin() -> Bool {
            if running { return false }
            running = true
            return true
        }

        func wait() async {
            guard running else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish() {
            running = false
            let pending = waiters
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }
}

// MARK: - 저장소

/// 키체인에 자격을 넣고 꺼낸다.
enum HomecomingCredentialStore {

    private static let service = "com.kona.homecoming2.credentials"
    private static let account = "device"

    /// 저장된 자격. 없으면 nil.
    static func load() -> HomecomingCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let saved = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return HomecomingCredentials(accountID: saved.accountID, token: saved.token)
    }

    /// 자격을 저장한다. 이미 있으면 덮어쓴다.
    static func save(_ credentials: HomecomingCredentials) {
        guard let data = try? JSONEncoder().encode(
            Stored(accountID: credentials.accountID, token: credentials.token)
        ) else { return }

        // 이 기기에서만, 잠금 해제된 뒤에만 읽힌다. 백업으로 새어 나가지 않는다.
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemDelete(baseQuery() as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// 자격을 지운다. 다음 실행에서 새 계정으로 등록된다.
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private struct Stored: Codable {
        let accountID: String
        let token: String
    }
}

// MARK: - 발급

enum HomecomingRegistrationError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "기기 등록 실패 (\(code))"
        }
    }
}

extension HomecomingCredentials {

    /// 저장된 자격을 쓰고, 없으면 서버에 등록해서 받아 온다.
    ///
    /// 등록은 인증이 필요 없는 유일한 엔드포인트다. 토큰을 받아 가는 길이니 그렇다.
    static func loadOrRegister(
        baseURL: URL,
        session: URLSession = .shared
    ) async throws -> HomecomingCredentials {
        if let saved = HomecomingCredentialStore.load() { return saved }

        var request = URLRequest(url: baseURL.appendingPathComponent("device/register"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw HomecomingRegistrationError.badResponse(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        struct Issued: Decodable { let accountId: String; let token: String }
        guard let issued = try? JSONDecoder().decode(Issued.self, from: data) else {
            throw HomecomingRegistrationError.badResponse(-2)
        }

        let credentials = HomecomingCredentials(accountID: issued.accountId, token: issued.token)
        HomecomingCredentialStore.save(credentials)
        return credentials
    }
}
