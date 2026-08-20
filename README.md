# 귀가마중 — Live Activity / Dynamic Island

집으로 돌아가는 과정을 **가족이 보는** Live Activity.
잠금화면 카드 하나와 Dynamic Island 세 프레젠테이션(확장 / 축소 / 최소)을 모두 구현했다.

**안전귀가 모드**(안심 확인 · 이상 상황 감시)는 **Phase 2** 다. 코드는 들어가 있지만
기본으로 꺼져 있고, Phase 1 흐름에는 나타나지 않는다.

> **지금 상태:** 앱과 서버가 모두 있다.
> [`Server/`](Server/README.md) 에 참조 구현이 있고(파일 하나, 의존성 없음),
> 형식은 [docs/API-SPEC.md](docs/API-SPEC.md) 에 정리했다.
> 실서비스 서버는 백엔드 팀이 자기 스택으로 옮기면 된다.
>
> Live Activity 에서 되는 것과 안 되는 것, 실주행 실측은
> [docs/LIVE-ACTIVITY.md](docs/LIVE-ACTIVITY.md) 에 있다.

## 열기

```bash
open Homecoming.xcodeproj
```

Dynamic Island 가 있는 기기·시뮬레이터(iPhone 14 Pro 이상)에서 실행하고,
**귀가 시작** 을 누른 뒤 홈으로 나가면 아일랜드에 표시된다.

프로젝트 파일은 손으로 관리하지 않고 생성한다. 파일을 추가한 뒤:

```bash
ruby Tools/generate_project.rb   # xcodeproj gem 필요
```

## 구조

```
Shared/                       앱 + 위젯 양쪽 타겟
  HomecomingAttributes        ActivityAttributes — 역할·단계·이동수단·이상 상황
  HomecomingWire              서버와 주고받는 표현 (ISO8601 날짜)
  HomecomingCheckIn           안심 확인 + LiveActivityIntent (잠금화면 버튼)

Widget/                       위젯 익스텐션 타겟
  HomecomingLiveActivity      ActivityConfiguration (잠금화면 + 아일랜드 4종)
  HomecomingViews             배지 · 진행 바 · 카운트다운 · 각 슬롯

App/
  HomecomingEnvironment       구성 요소 조립 (서버 주소 유무로 모드 결정)
  HomecomingActivityManager   Activity 시작 / 갱신 / 종료
  HomecomingCoordinator       실데이터 파이프라인: 위치 → 거리 → ETA → 액티비티
  CommuteSimulator            데모용 가짜 이동 재생기
  SafetyWatch                 이상 상황 판정 (지연 · 정지 · 무응답)
  ContractDump                API 명세용 페이로드를 실제 타입에서 덤프
  Location/
    HomePlace                 도착지 + 도착 반경, UserDefaults 저장
    HomePickerView            지도에서 집 임의 지정 (검색 · 반경 슬라이더)
    HomecomingLocationTracker CLLocationManager + 중요 위치 변경 + CLMonitor 지오펜스
  ETA/
    ETAProviding              추정기 프로토콜 + ETAEstimate
    TravelPace                실제 접근 속도 관측 → 외부 추정 보정
    TransitETAProvider        대중교통 추정 (서버 프록시)
    MapKitETAProvider         MapKit 도보/자동차 + 기기 내 추측 + 폴백 체인
  Session/
    SessionReporting          귀가 한 건을 서버에 보고 (시작 · 위치 · 종료)
  Watching/
    WatchingStore             내가 지켜보는 사람들의 현재 상태
    HomecomingJourneyCard     가족과 귀가자가 똑같이 보는 카드 (파일은 WatchingCard.swift)
  Pairing/
    PairingClient             초대 · 연결 · 해제 (서버 통신)
    PairingStore              페어링 상태
    PairingCard               가족 연결 화면
  Push/
    HomecomingBackend         토큰 업로드 통로 (서버 / 콘솔)
    HomecomingPushRegistrar   기기 · push-to-start · 액티비티 토큰 구독
    AppDelegate               APNs 기기 토큰 수신
```

## 상태 모델

`ContentState` 는 남은 분이 아니라 **도착 예정 시각(`expectedArrival`)** 을 담는다.
위젯이 `Text(timerInterval:)` 로 스스로 카운트다운하므로, 서버가 조용한 동안에도
화면이 멈춰 보이지 않는다. 추정한 순간과 액티비티가 뜨는 순간의 지연도 오차가 되지 않는다.

단계는 남은 거리로 정하되 **한 번 올라가면 내려오지 않는다**.
GPS 가 튀어서 "곧 도착"이 "이동 중"으로 되돌아가면 기다리는 가족이 혼란스럽다.

`곧 도착` 진입과 `도착` 순간에만 `AlertConfiguration` 으로 화면을 깨우고,
이동 중 갱신은 조용히 반영한다.

## 실데이터 파이프라인

### 1. 위치 — `HomecomingLocationTracker`

세 겹으로 돌린다.

| 경로 | 역할 |
|---|---|
| `startUpdatingLocation` | 주 경로. 남은 거리와 ETA 갱신 |
| `startMonitoringSignificantLocationChanges` | 앱이 종료돼도 시스템이 다시 깨워 준다 |
| `CLMonitor` 지오펜스 | 도착 판정. 이것만큼은 늦으면 안 된다 |

집에 가까워지면 정밀도를 `kCLLocationAccuracyNearestTenMeters` / 25m 필터로 올린다.
먼 구간에서 미터 단위로 켜 두면 배터리만 태운다.

`CLMonitor` 는 같은 이름으로 두 번 만들면 **ObjC 예외**를 던진다(Swift 에서 못 잡는다).
그래서 생성을 `sharedMonitor()` 한 곳으로 묶고 `startTracking` 을 멱등하게 만들었다.

### 2. ETA — `ETAProviding`

폴백 체인으로 엮는다. 앞이 실패하면 다음으로 넘어간다.

1. `TransitETAProvider` — 대중교통. 계산은 **우리 서버**가 한다
2. `MapKitETAProvider` — 기기 내 도보/자동차. 키도 서버도 필요 없다
3. `DeadReckoningETAProvider` — 직선 거리 × 우회 계수 ÷ 평속

벤더 API(TMAP·카카오·서울시 실시간 도착정보)를 앱에서 직접 부르지 않는 이유:
키가 번들에 들어가면 유출되고, 벤더를 갈아 끼울 때마다 앱을 새로 배포해야 하며,
무엇보다 **푸시를 쏘는 서버와 추정 로직을 공유할 수 없다.**

호출 빈도는 `HomecomingCoordinator` 가 조인다 — 45초 또는 400m 마다,
집 1km 안에서는 20초 / 120m 마다. 위치 픽스마다 부르면 서버도 배터리도 못 버틴다.
그 사이 남은 거리는 마지막 경로 거리에서 좁힌 직선 거리만큼 빼서 근사한다.

**MapKit 은 대중교통 경로를 못 준다.** 그리고 실측해 보니 교통량도 반영하지 않는다 —
강남 5.2km 자동차 경로에 5분(≈63km/h)을 돌려줬다. 귀가하는 지하철 사용자에게는
수단도 시간도 둘 다 틀린 값이다. `TransitETAProvider` 가 붙기 전까지는 어림값으로만 봐야 한다.

진단은 화면의 **이동 수단 / 추정 출처** 행과 로그 한 줄로 한다:
`ETA mapKit 수단=car 경로=5234m 직선=3401m 5분`

요청·응답 형식은 `TransitETAProvider` 주석에 적어 뒀다. 붙이려면 Info.plist 의
`HomecomingBackendBaseURL` 만 채우면 된다. 비어 있으면 MapKit 모드로 떨어진다.

### 2-1. 관측 보정 — `TravelPace`

외부 추정은 출발 시점의 예측일 뿐이다. 실제로 얼마나 빨리 가까워지는지는 우리가 이미 알고 있다.

**지면 속도가 아니라 접근 속도를 잰다.** 버스가 돌아가는 구간에서는 시속 40km 로 달려도
집과는 안 가까워진다. 도착 시각을 맞히는 데 필요한 건 후자다.

관측은 외부 추정을 **대체하지 않고 섞는다**. 관측 구간이 길수록 비중이 커지고 70% 에서 멈춘다.
출발 직후에는 근거가 없고, 신호등 하나에 멈춰도 값이 튀기 때문이다.
90초 미만이거나 150m 를 못 좁혔으면 아예 쓰지 않는다.

> **척도를 섞으면 안 된다.** 관측은 **직선거리**로 잰다.
> 경로 기반 남은 거리는 ETA 를 새로 받을 때마다 기준점이 재설정돼서,
> 그 값으로 속도를 재면 갱신 주기가 관측 창을 계속 잘라 먹어 아무것도 측정되지 않는다.
> 실제로 처음엔 이렇게 짜서 보정이 영영 안 걸렸다.
> 재는 쪽과 나누는 쪽이 같은 척도여야 한다.

도착 예정이 매 갱신마다 몇 초씩 흔들리면 카운트다운이 앞뒤로 튄다.
20초 미만의 변화는 내보내지 않는다.

화면의 **관측 보정** 행에 `39km/h · 40% 반영` 형태로 표시된다.

### 3. 푸시 — `HomecomingPushRegistrar`

토큰 세 종류를 스트림으로 계속 듣는다. 셋 다 언제든 재발급된다.

| 토큰 | 역할 |
|---|---|
| APNs 기기 토큰 | 일반 푸시 |
| **push-to-start** | 서버가 앱 없이 액티비티를 *시작*시킨다 |
| 액티비티 갱신 토큰 | 이미 뜬 액티비티에 새 상태를 밀어 넣는다 |

**가족 기기에 귀가 알림을 띄우는 건 전적으로 push-to-start 토큰에 달려 있다.**
지금 코드는 내 기기에 내 액티비티를 띄우고 토큰을 서버에 올리는 데까지다.
가족 기기 쪽은 서버가 그 토큰으로 APNs 를 쏘면 된다.

액티비티는 `Activity<>.activityUpdates` 로 발견한다. 우리가 시작한 것이든
서버가 push-to-start 로 띄운 것이든 같은 스트림으로 들어오므로 경로를 나눌 필요가 없다.

## 역할 — 누가 보는가

한 번의 귀가에 액티비티가 여러 개 뜬다. 본인 기기에 하나, 기다리는 가족 각자의 기기에 하나씩.
`HomecomingAttributes.audience` 가 그것을 가른다.

| | 귀가자 (`traveler`) | 가족 (`watcher`) |
|---|---|---|
| 헤드라인 | "가족에게 공유 중" | "아빠 집으로 가는 중" |
| 안심 확인 | **버튼** | 남은 시간 표시만 |
| 도착 예정 · 진행 바 · 이상 상황 | **동일** | **동일** |

**화면은 달라도 값은 같아야 한다.** 가족이 보는 도착 시각과 본인이 보는 것이 다르면
그 순간 이 서비스는 믿을 수 없는 것이 된다. 그래서 서버는 `content-state` 를
한 번 계산해 그대로 팬아웃하고, 수신자마다 다른 것은 `audience` 하나뿐이다.

안심 확인 버튼이 본인에게만 있는 이유도 같다 — 가족이 대신 눌러 줄 수 있으면
확인이라는 행위 자체가 의미를 잃는다.

## 집 위치 지정

두 가지 경로가 있다.

- **현재 위치를 집으로** — 집에서 한 번 누르면 끝. 반경은 기본값 120m.
- **지도에서 지정** — 임의의 위치. 주소·건물명 검색, 반경 조절까지.

지도는 핀을 탭해서 찍는 대신 **지도를 움직여 중앙에 맞추는** 방식이다.
한 손으로 쓸 수 있고, 손가락에 가려지지 않으며, 정밀한 탭을 요구하지 않는다.

지도를 멈추면 그 자리 주소로 이름을 채워 준다(역지오코딩). 사용자가 이름을 직접 고쳤으면
건드리지 않는다 — 이 구분을 `onChange` 로 하면 역지오코딩이 채운 값까지 '편집'으로 오인하므로,
TextField 의 setter 에서만 표시한다.

### 반경 하한이 100m 인 이유

iOS 지역 감시는 100m 아래에서 신뢰도가 급격히 떨어진다.
슬라이더를 50m 까지 열어 주면 "도착 알림이 안 와요" 로 돌아온다. 100~500m 로 묶었다.

이 값은 그대로 `CLMonitor` 지오펜스 반경과 `stage(forRemainingMeters:arrivalRadius:)` 의
도착 판정에 쓰인다. 아파트 단지와 단독주택은 '도착'의 크기가 다르다.

### 중앙 핀 정렬

핀은 지도의 **확장된** 프레임 위에 얹어야 한다.
`ignoresSafeArea` 를 오버레이 안쪽에 걸면 지도만 확장돼, 핀이 가리키는 지점과
반경 원의 중심이 세이프에어리어의 절반만큼 어긋난다. 화면으로만 보면 알아채기 어렵다.

## 안전귀가 모드 `[Phase 2]`

> 지금 범위 밖이다. 기본으로 꺼져 있고, 켜야만 아래가 나타난다.
> 서버 쪽 요구사항도 [API 명세서](docs/API-SPEC.md)에서 `[P2]` 로 갈라 뒀다.

`coordinator.safetyMode` 를 켜면 두 가지가 추가된다.

### 안심 확인 (데드맨 스위치)

15분마다 확인을 눌러야 한다. 마감을 넘기면 `.unresponsive` 로 올라가고 화면이 울린다.

버튼은 **잠금화면과 확장된 다이나믹 아일랜드에 직접 들어간다**(`LiveActivityIntent`).
앱을 열지 않고 끝나는 것이 핵심이다 — 위급할 때 앱을 찾아 실행할 시간은 없다.

`LiveActivityIntent` 는 위젯이 아니라 **앱 프로세스에서** 수행된다.
그래서 앱 그룹 없이도 같은 UserDefaults 를 본다.

축소 슬롯은 평소 도착까지 남은 분을 보여 주다가, 확인 마감이 3분 안으로 들어오면
그쪽 카운트다운으로 바뀐다. 좁은 자리에는 더 급한 것 하나만 올린다.

### 이상 상황 — 진행 단계와 다른 축

`stage` 는 집에 가까워지는 정도라 뒤로 가지 않는다(GPS 가 튀어도 되돌아가지 않게 막아 뒀다).
이상 상황은 그와 무관하게 떴다 사라진다. 늦어지다 따라잡을 수도 있고 도착 직전에 멈출 수도 있다.
**한 축에 욱여넣으면 둘 다 망가진다.**

| 값 | 판정 | 화면을 깨우나 |
|---|---|---|
| `delayed` | 도착 예정 + 10분 초과 | 아니오 |
| `stalled` | 80m 안에서 8분 이상, 집 400m 밖 | 아니오 |
| `offRoute` | 경로 폴리라인 필요 — **서버가 판정** | 예 |
| `unresponsive` | 안심 확인 마감 초과 | 예 |

지연·정지는 흔해서 조용히 반영만 한다. 울리는 알림이 흔해지면 아무도 안 본다.

동시에 여러 개가 성립하면 `priority` 가 낮은 하나만 보여 준다.

### 판정이 앱에서 끝나지 않는 이유

'멈춰 있음'과 '무응답'은 **정의상 아무 일도 일어나지 않을 때** 성립한다.
그 시점의 앱은 대개 잠들어 있어서 타이머도 위치 콜백도 돌지 않는다.
실제로 시뮬레이터에서 백그라운드 감시 루프가 멈추는 것을 확인했다.

두 가지로 대응한다.

1. **`staleDate` 를 확인 마감에 맞춘다.** 앱 코드가 한 줄도 돌지 않아도
   시스템이 그 시각에 화면을 흐리게 만든다. 공짜로 얻는 유일한 신호다.
2. **실서비스에서는 서버가 판정한다.** 마감 시각을 아는 쪽은 서버이고,
   푸시 토큰도 서버가 들고 있다. 앱 안의 판정은 깨어 있는 동안의 보조 장치일 뿐이다.

관련해서, 픽스가 2분 이상 끊겼다 돌아오면 그동안의 정지 시간은 근거로 쓰지 않는다.
앱이 잠들어 있던 것과 그 사람이 멈춘 것을 구분할 수 없기 때문이다.
구분할 수 없을 때 띄운 경고는 곧 아무도 안 믿는 경고가 된다.

### 넣지 않은 것

**긴급(SOS) 버튼.** 잠금화면에 보이는 긴급 버튼은 옆 사람에게도 보인다.
실제 안전 앱들이 소리 없는 트리거(볼륨 버튼 연타, 무응답 타임아웃)를 쓰는 이유다.
"안심 확인"은 드러내고 긴급은 숨기는 이중 구조가 맞다고 보고, 후자는 설계를 정한 뒤에 넣는 게 낫다.

**보호자가 세션을 시작하는 기능.** 이런 기능은 설계를 잘못하면 감시 도구가 된다.
당사자가 세션 단위로 켜고 언제든 혼자 끌 수 있어야 한다.
지금 구조가 그렇게 되어 있고, 반대 방향 요구가 들어오면 여기를 근거로 삼으면 된다.

## 알아 둘 것

- **도착 표시**: `end(...)` 를 부르는 순간 다이나믹 아일랜드는 알림을 즉시 치운다
  (잠금화면만 `dismissalPolicy` 만큼 남는다). 그래서 도착 상태로 20초 살려 둔 뒤 종료한다.
  기다리던 가족이 실제로 보는 건 그 몇 초다. 백그라운드 판정이 대부분이라
  `beginBackgroundTask` 로 감싼다.
- **끝난 액티비티 재부착 금지**: `Activity.activities` 에는 종료된 것도 잠시 남는다.
  그걸 붙잡으면 다음 귀가가 "이미 진행 중"으로 막힌다. `.active` / `.stale` 만 고른다.
- **앱 재시작**: 액티비티는 살아 있는데 추적이 꺼진 유령 상태가 생긴다.
  `coordinator.resumeIfNeeded()` 가 이걸 되살린다. 귀가 중에 앱이 메모리에서
  내려가는 건 예외가 아니라 기본값이다.
- **확장 영역 여백**: 좌우가 아일랜드 곡면에 물려 잘린다. `padding(.horizontal, 14)` 이상.
- **갱신 빈도**: 갱신할 때마다 아일랜드가 펼쳐져 화면을 가린다. 몰아서 보내는 편이 낫다.
- **축소·확장은 같은 타이머를 써야 한다**: 축소 슬롯에 분 단위 정수를 박아 두면
  갱신이 올 때만 바뀌어서, 스스로 흐르는 확장 화면과 다른 숫자를 보여 준다
  (반올림 차이 + 갱신 사이의 정지). 좁은 슬롯에 초가 흐르는 건 부산하지만
  **틀린 숫자가 부산한 숫자보다 나쁘다.** 양쪽 다 `Text(timerInterval:)` 로 통일했다.
- **시뮬레이터 서명**: 서명을 끄면 엔타이틀먼트가 번들에 안 들어가고
  `Activity.request(pushType: .token)` 이 실패한다. 시뮬레이터도 ad-hoc 서명한다.
  실패해도 로컬 갱신으로 후퇴하도록 해 뒀다.

## 검증 상태

시뮬레이터(iPhone 17 Pro, iOS 26)에서 확인한 것:

- 데모 / 실데이터 양쪽 경로로 액티비티 시작
- MapKit ETA 실측 (서울시청 → 4km 남쪽, 경로 4,778m)
- 위치 이동에 따른 축소·확장 아일랜드 갱신
- 거리 기반 도착 판정 → 도착 화면 → 종료 (백그라운드 포함)
- 앱 재시작 후 추적 재개
- 안전귀가: 확인 마감 임박 시 축소 슬롯 전환, 마감 초과 시 `.unresponsive` 판정
- 집 지정 화면 렌더링 · 중앙 핀과 반경 원 정렬
- 현재 위치 주소 표시 (역지오코딩)
- 관측 보정: 20초당 220m 이동 → `39km/h` 로 측정
- 축소·확장 카운트다운 일치 (양쪽 mm:ss, 3:19 → 3:12 로 함께 흐름)
- 세션 한 건 전체 — 시작 → 위치 보고 → 도착 종료
- 앱을 강제 종료했다 켜도 같은 세션으로 보고가 이어짐
- 페어링 왕복 — 코드 발급 → 가족이 입력 → 양쪽 목록 반영 → 해제
- 잘못된 코드는 "코드를 찾을 수 없습니다" 로 걸러짐
- 가족용 앱 화면 — 상대의 현황이 맨 위, 내 귀가는 아래
- 공유 중지 표시 — 도착(초록·집)과 확실히 구분되는 회색·"중지" 화면
- **서버 한 바퀴** — 페어링 → 세션 시작 → 가족에게 시작 알림 → 위치 4건
  (4059 → 2892 → 1670 → 672m, 단계 단조 증가) → 도착 판정 → 종료
- 역할별 렌더링 — 귀가자·가족 양쪽에서 같은 ETA(`6:27`) 표시
- 와이어 형식 — 날짜가 ISO8601 문자열로 나가는 것을 실제 덤프로 확인

**실기기(iPhone 14 Pro Max, iOS 18.7.3)에서 확인:**

- **push-to-start** — 앱이 실행 중이 아닌데 APNs 로 액티비티가 생성됨 (가족 기기 경로)
- **update 푸시** — `stage` · `remainingMeters` · `detail` 이 보낸 값 그대로 반영
- **ISO8601 날짜가 ActivityKit 푸시 디코더에서 정상 처리됨**
- **APNs 기기 토큰과 push-to-start 토큰이 시뮬레이터에서 발급됨**

확인하지 못한 것:

- **대중교통 ETA** — 서버가 없어 `TransitETAProvider` 경로는 미검증
- **가족 기기 2대 이상 동시 전송** — 기기가 하나뿐이라 다중 수신자는 미검증
- **잠금화면 카드** — 시뮬레이터를 잠글 수 없어 프리뷰로만 확인
- **지도 조작** — 팬·슬라이더·검색·저장 탭은 미검증. 렌더링과 정렬만 확인했다
- `[P2]` 안심 확인 버튼 탭, 백그라운드 이상 판정 — Phase 2 범위

## 가족이 앱을 열면

지금까지는 가족이 앱을 열어도 **귀가자용 조종석**(귀가 시작 버튼, 집 등록, 안전귀가 토글)이
그대로 나왔다. 기다리는 사람에게는 아무 쓸모가 없는 화면이다.

이제 지켜보는 사람이 있으면 그 현황이 **맨 위**에 오고, 내 귀가 관련 조작은 그 아래로 내려간다.

별도의 API 를 부르지 않는다. 서버가 이미 이 기기에 Live Activity 를 띄워 뒀고 그 안에
필요한 값이 다 들어 있으므로, 앱은 그걸 큰 화면으로 다시 보여 줄 뿐이다.
**가족 기기는 아무것도 계산하지 않는다** 는 원칙이 여기서도 유지된다.

> 끝난 액티비티를 `.ended` 시점에 지우면 안 된다. 잠금화면에는 남아 있는데 앱에서만
> 사라지면 가족은 왜 조용해졌는지 볼 기회를 잃는다. `.dismissed` 까지 함께 보여 준다.

### 도착과 공유 중지는 다르다

`endReason` 이 그것을 가른다. 중지되면 회색, 눈 가림 아이콘, "공유를 껐어요",
카운트다운 자리에는 "중지", 도착 예정 시각은 감춘다.

`stage` 로는 표현할 수 없다 — 중지는 진행이 아니라서 단계에 자리가 없다.
그리고 조용해진 이유를 모르면 안전귀가라고 할 수 없다.

## 가족 연결 (페어링)

**승인 주체는 귀가자다.** 가족이 일방적으로 붙을 수 있으면 이건 감시 도구가 된다.

1. 귀가자가 **초대 코드**를 만든다 (30분 유효). 코드에는 귀가자 이름이 함께 실린다 —
   가족은 코드를 입력하는 순간 자기가 누구를 지켜보게 되는지 알아야 한다
2. 가족이 코드와 자기 이름을 입력해 연결한다
3. 양쪽 다 목록에서 상대를 **혼자 끊을 수 있다**

한 사람이 귀가자이면서 동시에 다른 사람을 지켜볼 수 있으므로 두 역할을 한 화면에 담았다.
해제를 귀가자만 할 수 있게 하면 가족이 원치 않는 연결에 묶이고,
가족만 할 수 있게 하면 귀가자가 통제를 잃는다.

코드는 헷갈리는 글자(`O`/`0`, `I`/`1`)를 뺀 5자리다. 전화로 불러 줄 수 있어야 한다.

**연결은 서버에만 존재한다.** 서버가 없으면 페어링 자체가 성립하지 않고, 화면도 그렇게 말한다.

## 서버 세션 — 가족에게 닿는 유일한 경로

귀가자 기기가 아무리 정확히 계산해도 그 값은 자기 화면에만 남는다.
**서버가 알아야 가족 기기로 보낼 수 있다.** `SessionReporting` 이 그 통로다.

| 시점 | 호출 | 서버가 하는 일 |
|---|---|---|
| 귀가 시작 | `POST /session/start` | 가족들에게 push-to-start 로 알림을 띄운다 |
| 이동 중 | `POST /session/{id}/location` | ETA·도착을 판정하고 가족 화면을 갱신한다 |
| 도착·중지 | `POST /session/{id}/end` | 알림을 마무리한다 |

보고 주기는 15초 또는 100m 마다, 집 1km 안에서는 8초 / 40m 마다.
실패한 보고는 다시 보내지 않는다 — 다음 위치가 곧 그것을 대신한다.

**세션 ID 는 저장해 둔다.** 귀가 중에 앱이 메모리에서 내려가는 건 기본값이고,
다시 켜졌을 때 같은 세션으로 이어 보고하지 않으면 가족 화면이 마지막 값에서 멈춘다.

## 서버

```bash
python3 Server/homecoming_server.py
xcrun simctl launch $UDID com.kona.homecoming2 -homecomingBackend "http://localhost:8787"
```

APNs 키를 넣으면 실제로 가족 기기에 알림이 뜬다 — 자세한 건 [Server/README.md](Server/README.md).

## 목 서버로 서버 경로 확인

```bash
python3 Tools/mock-server.py                      # 정상
python3 Tools/mock-server.py --fail 500           # 폴백 확인
python3 Tools/mock-server.py --delay 10           # 타임아웃 폴백 확인

xcrun simctl launch $UDID com.kona.homecoming2 \
  -homecomingBackend "http://localhost:8787" \
  -homecomingHome "37.5300,126.9800" -autoLiveHomecoming
```

## 실기기에서 APNs 확인

```bash
python3 Tools/apns-push.py update --dry-run       # 페이로드만 확인
python3 Tools/apns-push.py update \
  --key AuthKey_XXX.p8 --key-id XXX --team-id YYY \
  --token <액티비티 갱신 토큰> --remaining 3200 --eta-minutes 12
```

## 시뮬레이터에서 손 안 대고 재생

```bash
UDID=<simulator udid>
xcrun simctl privacy $UDID grant location-always com.kona.homecoming2
xcrun simctl location $UDID set 37.5665,126.9780

# 실데이터 경로: 집을 등록하고 바로 출발
xcrun simctl launch $UDID com.kona.homecoming2 \
  -homecomingHome "37.5300,126.9800" -autoLiveHomecoming

# 안전귀가 모드 (검증용으로 확인 주기를 40초로)
xcrun simctl launch $UDID com.kona.homecoming2 \
  -homecomingHome "37.5300,126.9800" -autoLiveHomecoming \
  -homecomingSafetyMode on -homecomingCheckInSeconds 40

# 집 지정 화면 바로 띄우기
xcrun simctl launch $UDID com.kona.homecoming2 -homecomingShowHomePicker

# 데모 재생
xcrun simctl launch $UDID com.kona.homecoming2 -autoStartHomecoming

xcrun simctl launch $UDID com.apple.Preferences   # 백그라운드로 보내야 아일랜드가 보인다
xcrun simctl location $UDID set 37.5302,126.9799  # 집 앞으로 이동 → 도착
```

로그:

```bash
xcrun simctl spawn $UDID log show --last 2m \
  --predicate 'subsystem == "com.kona.homecoming2"' --info --debug --style compact
```
