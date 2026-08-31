# 잠금화면에서 버스 도착 새로고침 — 설계 (2026-08-28)

> ## 닫혔다 — 안 만든다 (2026-08-31)
>
> **전제가 틀렸다.** 이 문서는 *"잠금화면 값이 낡으니 눌러서 새로 받아야 한다"* 를
> 깔고 있었다. 실제로 재 보니 **잠금 상태에서도 33초마다 저절로 갱신된다.**
>
> 귀가를 시작하고 앱을 닫고 폰을 잠근 채 8분 두었다(2026-08-31 KST 10:04~10:13).
>
> ```
> bus-arrival   01:05:26 · 05:57 · 06:31 · 07:05 · 07:38 · 08:11 · 08:44 · 09:17
>               · 09:50 · 10:23 · 10:56 · 11:29 · 12:02 · 12:35 · 13:08   (UTC)
>               → 33초 간격, 8분 내내 한 번도 안 끊김
> location      01:04:58 · 06:59 · 09:02 · 11:05 · 13:08
>               → 121·123·123·123초. heartbeat 이 코드대로 120초로 돈다
> ```
>
> **앱을 닫고 잠갔는데 30초 타이머가 계속 돌았다.** `UIBackgroundModes: location`
> 덕에 앱이 잠들지 않아 탭에 붙은 `.task` 가 살아 있다. 사용자가 다이나믹
> 아일랜드에서 값이 바뀌는 것도 눈으로 확인했다.
>
> 그러니 버튼이 사는 값은 **0에 가깝다.** 반면 치르는 값은 자격 파일
> (`HomecomingCredentials.swift`)을 `Shared/` 로 옮기는 것 — 이번 주에 가장
> 아팠던 코드다.
>
> **다시 꺼낼 조건** — 위 33초가 깨질 때. iOS 가 백그라운드 정책을 조이거나,
> `.task` 가 탭에서 떨어져 나가거나, `sawBusArrival` 조건 밖(승차 창 밖)에서도
> 잠금화면 값이 필요해질 때다. 그때는 아래 설계를 그대로 쓰면 된다.
>
> 함께 검토했다가 같이 접은 안 — **heartbeat 를 30초로 단축.** 버스 값을 굴리는
> 것이 heartbeat 가 아니라 30초 타이머라 애초에 상관없는 손잡이였다.

**구현하지 않았다.** 설계만 해 둔 것이고, 위와 같이 닫혔다.

앱 카드의 `↻` 를 잠금화면과 다이나믹 아일랜드에서도 누를 수 있게 한다. 정류장에서
폰을 꺼내 잠금화면만 보는 그 순간이 정확히 `↻` 가 필요한 자리다 — 지금은 앱을 열어야
한다.

## 지금 상태

`BusArrivalChip` 은 세 화면이 함께 쓴다(2026-08-28). 그런데 **버튼은 앱에만 있다.**

```swift
if state.busArrivalNo != nil {
    BusArrivalChip(state: state)          // onRefreshBusArrival 을 안 넘긴다 → 버튼 없음
}
```

일부러 그렇게 뒀다. 위젯 컨텍스트에서 일반 `Button { }` 은 그려지기만 하고 안 눌린다.
칩의 주석이 그 규율을 적어 뒀다 — *"눌러도 아무 일 없는 버튼은 없는 것보다 나쁘다."*

## 되는 길은 이미 이 저장소에 있다

`CheckInButton` 이 같은 문제를 이미 풀었다 — `Button(intent:)` + `LiveActivityIntent`.

그리고 결정적인 사실이 `HomecomingCheckIn.swift` 주석에 기록돼 있다.

> `LiveActivityIntent` 는 **앱 프로세스에서** 수행되므로 앱 그룹 없이도 같은
> UserDefaults 를 본다. 위젯 익스텐션에서 돌았다면 앱 그룹이 필요했다.

**같은 이유로 키체인도 닿는다.** `HomecomingCredentialStore` 는 접근 그룹을 안 쓰고
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 로 저장하므로, 앱 프로세스에서
`load()` 가 그대로 된다. `Bundle.main` 도 앱이라 `HomecomingBackendBaseURL` 이 읽힌다.

**앱이 죽어 있어도 된다.** iOS 가 인텐트를 위해 앱 프로세스를 띄운다. 다만 그때
`HomecomingEnvironment` 는 없다 — 그래서 `HomecomingCheckIn` 처럼 **전부 static 으로
자립해야** 한다. 코디네이터를 부를 수 없다.

## 무엇이 막고 있나 — 타깃 경계

버튼을 **위젯이 그리므로** 인텐트 타입이 위젯 타깃에도 컴파일돼야 한다.
`generate_project.rb:150` 이 `Shared/` 만 양쪽에 넣는다.

```
Shared/   Attributes · CheckIn · ViewParts · Wire          ← 위젯도 컴파일
App/      HomecomingCredentials.swift    (토큰)            ← 위젯이 못 본다
App/      HomecomingEnvironment.swift    (서버 주소)        ← 위젯이 못 본다
App/      Session/SessionReporting.swift (POST 호출)       ← 위젯이 못 본다
```

`HomecomingCheckIn` 이 `Shared/` 에서 살 수 있는 이유는 **망을 안 타기 때문**이다 —
ActivityKit 과 UserDefaults 만 만진다. 도착 새로고침은 서버를 불러야 한다.

## 무엇을 만드나

### 1. `Shared/HomecomingBackendAccess.swift` (새 파일)

서버에 닿는 데 필요한 최소한만 담는다. **자립해야 하고, 위젯 타깃에서 컴파일되지만
거기서 실행되지는 않는다.**

```swift
enum HomecomingBackendAccess {
    static var baseURL: URL?      // 런치 인자 → Info.plist  (지금 `configuredBackendURL` 과 같은 규칙)
    static var token: String?     // HomecomingCredentialStore.load()?.token
}
```

**`HomecomingCredentials.swift` 를 `Shared/` 로 옮긴다.** 코드는 한 줄도 안 고친다 —
타깃 소속만 바뀐다. `import Foundation` · `import Security` 뿐이라 위젯에서도 컴파일된다.

**쪼개서 일부만 옮기지 않는다.** 그 파일에는 401 을 받으면 자격을 버리는 코드가 있고,
2026-08-28 에 그것 때문에 저장한 경로와 가족 페어링이 사라진 것처럼 보였다. 손댈수록
위험하다.

`configuredBackendURL()` 은 `HomecomingEnvironment` 에서 `HomecomingBackendAccess` 로
옮기고, 환경은 그것을 부른다. **두 벌로 두지 않는다** — 주소가 갈리면 앱과 인텐트가
다른 서버를 본다.

### 2. `Shared/HomecomingBusRefresh.swift` (새 파일)

`HomecomingCheckIn.swift` 와 같은 모양이다.

```swift
enum HomecomingBusRefresh {
    @discardableResult
    static func refresh(activityID: String) async -> Bool
}

struct HomecomingRefreshBusArrivalIntent: LiveActivityIntent { … }
```

`refresh` 가 하는 일 —

```
액티비티를 id 로 찾는다                          없으면 false
attributes.sessionID 를 읽는다                   코디네이터가 아니라 고정값에서
POST {baseURL}/session/{id}/bus-arrival          Authorization: Bearer {token}
받은 ContentState 를 액티비티에 반영한다
```

**세션 id 를 고정값에서 읽는 것이 핵심이다.** 코디네이터는 그 자리에 없다.

### 3. 반영은 `adopt` 의 규칙을 그대로 써야 한다

여기가 이 설계에서 가장 조용히 깨질 자리다. `HomecomingActivityManager.adopt` 는
이렇게 한다.

```swift
var state = incoming
state.checkInDeadline = previous.checkInDeadline    // 서버가 모르는 값
state.anomaly = previous.anomaly                    // 서버가 모르는 값
guard state != previous else { return }             // 같으면 안 밀어 예산을 아낀다
```

**인텐트가 이 셋을 안 지키면 안심 확인 마감과 이상 상황이 사라진다.** `CLAUDE.md` 가
경고하는 네 번째 자리와 같은 종류다 — *"필드를 안 쓰는 것이 곧 지우는 것"*.

그래서 **베끼지 않고 옮긴다.** 병합 규칙을 `Shared/` 의 함수 하나로 빼고
(`HomecomingAttributes.ContentState.merging(over:)` 같은 것) `adopt` 와 인텐트가 그
하나를 쓴다. 두 벌이 되면 한쪽만 고치는 사고가 난다 — 이 저장소에 이미 그 기록이 있다
(`↻` 가 163 만 새로 묻던 것, 2026-08-28).

### 4. 칩이 버튼을 두 방식으로 그린다

```swift
BusArrivalChip(state:, onRefreshBusArrival:)   앱 — 지금 그대로, Button { }
BusArrivalChip(state:, activityID:)            위젯 — Button(intent:)
```

**귀가자에게만 그린다.** `attributes.audience == .traveler` 일 때만 `activityID` 를
넘긴다. 가족은 남의 세션을 조회할 권한이 없어 서버가 거절한다 — 앱 카드가 이미 같은
규칙을 쓴다(`onRefreshBusArrival` 을 귀가자 카드만 넘긴다).

### 5. `ruby Tools/generate_project.rb`

파일이 늘고 `HomecomingCredentials.swift` 가 옮겨지므로 재생성한다.

## 안 하는 것

- **가족 기기에서 누르기** — 서버가 남의 세션 조회를 거절한다. 권한을 새로 만드는
  일이고 이 설계 밖이다.
- **화살표 회전** — 위젯에서는 `withAnimation` 이 안 돈다. 인텐트가 도는 동안
  아일랜드가 스스로 갱신되지도 않는다. 누르면 값이 바뀌는 것으로 알 수 있으니
  회전 없이 둔다. **돌지도 않는 것을 도는 척 그리지 않는다.**
- **자격 저장 로직 손보기** — 옮기기만 한다.

## 검증

시험으로 잡히는 것이 거의 없다. **화면과 서버 로그로 본다.**

```bash
python3 -m unittest discover -s Server        # 246개 — 회귀만 본다
railway logs --service homecoming2 | grep bus-arrival
```

실기기에서 볼 것 —

```
귀가 중 잠금화면에서 ↻ 가 뜨는가            승차 15분 전, 999 구간
눌렀을 때 서버 로그에 POST 가 찍히는가       가족 기기에서는 ↻ 가 안 떠야 한다
값이 바뀌는가                             칩의 시각이 갱신되는가
앱을 완전히 종료한 뒤에도 되는가             iOS 가 앱 프로세스를 띄우는지
안심 확인 마감이 살아 있는가                 adopt 규칙을 지켰는지 — 이게 조용히 깨진다
```

**마지막 줄이 이 설계의 진짜 위험이다.** 새로고침은 되는데 안심 확인 마감이 사라지면,
안전귀가 모드가 조용히 무응답으로 넘어간다.

## 왜 지금 안 했나

지금까지 올린 것들 — 지도 줌·도착예정·화살표·아일랜드 칩 — 이 **아직 실귀가를 한 번도
안 지났다.** 자격 코드를 만지는 작업을 그 위에 얹으면, 무엇이 깨졌을 때 어느 것 때문인지
가릴 수 없다. 한 번 타 보고 나서 붙인다.
