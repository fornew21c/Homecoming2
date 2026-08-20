#!/bin/bash
#
# 귀가 한 바퀴를 명령 하나로 돌린다.
#
#   Tools/e2e-device.sh
#
# 귀가자는 스크립트가 대신한다(위치를 curl 로 흘린다). 가족은 실기기다 —
# 확인하려는 게 "서버가 쏜 푸시가 실기기 잠금화면에 뜨는가" 이기 때문이다.
#
# 연결된 실기기를 전부 가족으로 붙인다. 두 대면 두 대가 같은 값으로 갱신되는지까지 본다.
#
# 옵션
#   --backend <주소>   서버 주소. 기본은 맥의 로컬 서버.
#                      배포된 서버를 주면 **집 밖에서도 되는지**를 시험한다 —
#                      로컬로 도는 건 폰과 맥이 같은 Wi-Fi 일 때만 통한다
#   --route <파일>     저장된 경로로 돈다. 카드에 "지하철 · 풍산역까지 12분" 이 뜬다
#   --play-speed N     경로 재생 압축 배수 (기본 25 → 84분 경로가 3분 반)
#   --home "lat,lon"   집 좌표 (--route 없을 때만. 기본 서울시청)
#   --skip-install     빌드·설치 건너뛰기 (이미 깔려 있을 때)
#   --regen            Xcode 프로젝트를 다시 만든다
#   --keep             끝나고 서버 DB 를 지우지 않는다
#
# **--regen 은 Xcode 가 열려 있을 때 쓰지 마라.** 프로젝트 파일이 Xcode 밑에서
# 갈리면서 contents.xcworkspacedata 가 사라지고 다시 안 열린다. 한 번 겪었다.
# 파일이 새로 생기지 않았으면 재생성할 이유가 없다.
#
set -euo pipefail

cd "$(dirname "$0")/.."

BACKEND_LOCAL="http://127.0.0.1:8787"
BACKEND_OVERRIDE=0
BUNDLE_ID="com.kona.homecoming2"
HOME_LAT="37.5665"
HOME_LON="126.9780"
SKIP_INSTALL=0
KEEP_DB=0
REGEN=0
ROUTE=""
PLAY_SPEED=25
DD="${TMPDIR:-/tmp}/homecoming-dd-device"

while [ $# -gt 0 ]; do
  case "$1" in
    --backend)      BACKEND_LOCAL="$2"; BACKEND_OVERRIDE=1; shift 2 ;;
    --route)        ROUTE="$2"; shift 2 ;;
    --play-speed)   PLAY_SPEED="$2"; shift 2 ;;
    --home)         IFS=, read -r HOME_LAT HOME_LON <<< "$2"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --regen)        REGEN=1; shift ;;
    --keep)         KEEP_DB=1; shift ;;
    *) echo "모르는 옵션: $1" >&2; exit 2 ;;
  esac
done

[ -z "$ROUTE" ] || [ -f "$ROUTE" ] || { echo "경로 파일이 없다: $ROUTE" >&2; exit 2; }

step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

# ------------------------------------------------------------------ 0. 서버

step "서버 확인"
HEALTH=$(curl -sS --max-time 3 "$BACKEND_LOCAL/health" 2>/dev/null || true)
[ -n "$HEALTH" ] || die "서버가 안 떠 있다. 먼저 띄워라:
    export HOMECOMING_APNS_KEY=/path/AuthKey_XXXXXXXXXX.p8
    export HOMECOMING_APNS_KEY_ID=XXXXXXXXXX
    export HOMECOMING_TEAM_ID=YYYYYYYYYY
    python3 Server/homecoming_server.py"
ok "서버 응답 $HEALTH"

case "$HEALTH" in
  *'"apns": true'*|*'"apns":true'*) ok "APNs 설정됨" ;;
  *) die "APNs 미설정. 이 스크립트는 실기기에 알림이 뜨는 걸 보는 게 목적이라
     APNs 없이는 의미가 없다. HOMECOMING_APNS_* 를 넣고 서버를 다시 띄워라." ;;
esac

DB_PATH="${HOMECOMING_DB:-Server/homecoming.sqlite}"

# 기기 상태는 **서버에 물어서** 판정한다. 예전에는 서버의 SQLite 를 직접 열었는데,
# 그건 서버가 이 기계에 있을 때만 되는 방법이었다. 배포한 서버로도 같은 스크립트가
# 돌아야 한다 — "집 밖에서도 되는가" 가 이 시험의 요점이기 때문이다.
#
# JSON 한 겹에서 값 하나를 뽑는다. 따옴표가 있든 없든 받는다.
field() { sed -n "s/.*\"$1\": *\"\{0,1\}\([^,\"}]*\).*/\1/p"; }

# status <토큰> <키> → true / false / 값
status() { as "$1" "$BACKEND_LOCAL/push/status" | field "$2"; }

# 세션 상태. 서버의 SQLite 를 직접 열던 것을 대신한다.
# session_field <키>
session_field() { as "$TRAVELER_TOKEN" "$BACKEND_LOCAL/session/$SESSION" | field "$1"; }

# 서버가 X-Account-Id 를 더 믿지 않는다. 기기마다 토큰을 받아서 그걸로 몬다.
register_device() {
  curl -sS -X POST "$BACKEND_LOCAL/device/register" \
    -H 'Content-Type: application/json' -d '{}'
}
# as <token> <curl 인자...>
as() { local t="$1"; shift; curl -sS -H "Authorization: Bearer $t" "$@"; }

# 기기마다 계정을 **유지한다.** 실행마다 새로 만들면 두 번째 실행부터 실패한다.
#
# push-to-start 토큰 스트림은 값이 **바뀔 때만** 흐른다. 앱을 다시 켠다고 다시 주지
# 않는다. 그래서 첫 실행에서 올라간 토큰은 그때의 계정에 남고, 새 계정으로 갈아 타면
# 서버는 그 기기의 토큰을 영영 모른다 — 실제로 "닿기는 하는데 토큰이 없다" 로 죽었다.
KEY_DIR="$HOME/.homecoming-e2e"
mkdir -p "$KEY_DIR"

# device_account <udid> → "계정id 토큰"
device_account() {
  local file="$KEY_DIR/$1" id token json
  if [ -f "$file" ]; then
    read -r id token < "$file"
    # 서버가 바뀌었거나 DB 를 지웠으면 옛 토큰은 죽었다. 살아 있을 때만 재사용한다.
    if [ "$(as "$token" -o /dev/null -w '%{http_code}' "$BACKEND_LOCAL/route")" = "200" ]; then
      printf '%s %s\n' "$id" "$token"
      return
    fi
  fi
  json=$(register_device)
  id=$(echo "$json" | sed -n 's/.*"accountId": *"\([^"]*\)".*/\1/p')
  token=$(echo "$json" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
  [ -n "$token" ] || die "기기 $1 토큰을 못 받았다."
  printf '%s %s\n' "$id" "$token" > "$file"
  printf '%s %s\n' "$id" "$token"
}

# 기기가 붙을 주소.
#
# 로컬 서버로 돌 때는 실기기가 127.0.0.1 로 맥에 못 오므로 `.local` 이름을 준다.
# 배포 서버로 돌 때는 그 주소를 그대로 쓴다 — 그게 이 시험의 요점이다.
MAC_HOST="$(scutil --get LocalHostName).local"
if [ "$BACKEND_OVERRIDE" = "1" ]; then
  BACKEND_DEVICE="$BACKEND_LOCAL"
else
  BACKEND_DEVICE="http://$MAC_HOST:8787"
fi
ok "기기가 쓸 주소 $BACKEND_DEVICE"

# ------------------------------------------------------------------ 1. 기기

step "귀가자 기기 등록"
TRAVELER_JSON=$(register_device)
TRAVELER=$(echo "$TRAVELER_JSON" | sed -n 's/.*"accountId": *"\([^"]*\)".*/\1/p')
TRAVELER_TOKEN=$(echo "$TRAVELER_JSON" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
[ -n "$TRAVELER_TOKEN" ] || die "귀가자 토큰을 못 받았다."
ok "귀가자 $TRAVELER"

step "연결된 실기기"
DEVICES=()
while IFS= read -r line; do
  [ -n "$line" ] && DEVICES+=("$line")
done < <(
  xcrun devicectl list devices 2>/dev/null \
    | awk '/connected/ && /iPhone/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}/) { print $i; break } }'
)

[ "${#DEVICES[@]}" -gt 0 ] || die "연결된 아이폰이 없다.
  케이블로 꽂고, 기기에서 '이 컴퓨터를 신뢰' 를 누르고,
  설정 → 개인정보 보호 및 보안 → 개발자 모드를 켜라(재부팅 필요)."

WATCHER_NAMES=(MOM AUNT UNCLE GRANDMA)
for i in "${!DEVICES[@]}"; do
  ok "가족 ${WATCHER_NAMES[$i]} ← ${DEVICES[$i]}"
done
[ "${#DEVICES[@]}" -ge 2 ] || bad "기기가 한 대다. '가족 2대 동시' 는 이번에 확인 못 한다."

# ------------------------------------------------------------------ 2. 설치

if [ "$SKIP_INSTALL" = "0" ]; then
  step "빌드 · 설치"
  [ -n "${HOMECOMING_TEAM_ID:-}" ] || die "HOMECOMING_TEAM_ID 가 필요하다(기기 서명)."
  # 프로젝트 재생성은 파일이 새로 생겼을 때만 필요하다. Xcode 가 열려 있는데
  # 재생성하면 그 밑에서 파일이 갈려서 프로젝트가 다시 안 열린다.
  if [ "$REGEN" = "1" ] || [ ! -f Homecoming.xcodeproj/project.pbxproj ]; then
    ruby Tools/generate_project.rb >/dev/null
    ok "프로젝트 생성"
  else
    ok "프로젝트 그대로 (재생성은 --regen)"
  fi
  xcodebuild -project Homecoming.xcodeproj -scheme Homecoming -configuration Debug \
    -destination "id=${DEVICES[0]}" -derivedDataPath "$DD" \
    -allowProvisioningUpdates build >/tmp/homecoming-build.log 2>&1 \
    || die "빌드 실패. /tmp/homecoming-build.log 를 봐라."
  ok "빌드 성공"

  APP="$DD/Build/Products/Debug-iphoneos/Homecoming.app"
  for d in "${DEVICES[@]}"; do
    xcrun devicectl device install app --device "$d" "$APP" >/dev/null \
      || die "$d 설치 실패. 새 기기면 프로비저닝에 등록되며 한 번 더 빌드가 필요할 수 있다."
    ok "$d 설치"
  done
else
  step "설치 건너뜀 (--skip-install)"
  APP="$DD/Build/Products/Debug-iphoneos/Homecoming.app"
fi

# ------------------------------------------------------------------ 3. 토큰

step "가족 앱 실행 — push-to-start 토큰 등록"
echo "  토큰이 없으면 서버가 알림을 조용히 건너뛴다(start_activities)."
echo "  기기에 알림 권한 팝업이 뜨면 '허용' 을 눌러라."

WATCHER_IDS=()
WATCHER_TOKENS=()
for i in "${!DEVICES[@]}"; do
  read -r acct_id acct_token < <(device_account "${DEVICES[$i]}")
  WATCHER_IDS+=("$acct_id")
  WATCHER_TOKENS+=("$acct_token")
  ok "가족 ${WATCHER_NAMES[$i]} 계정 $acct_id"
done

for i in "${!DEVICES[@]}"; do
  # 실행 오류를 버리지 않는다. 한 번 버려서 원인 찾는 데 한참 걸렸다.
  # 토큰을 주입한다 — 기기 한 대로 여러 역할을 시험하려면 이 길밖에 없다.
  xcrun devicectl device process launch --terminate-existing --device "${DEVICES[$i]}" "$BUNDLE_ID" -- \
    -homecomingBackend "$BACKEND_DEVICE" \
    -homecomingToken "${WATCHER_TOKENS[$i]}" \
    -homecomingAudience watcher 2>&1 | grep -v '^1[0-9]:' | grep -vi "^Launched" || true
done

# 토큰이 없는 이유는 둘인데 증상이 같다. 여기서 갈라 준다.
#   - 기기가 서버에 아예 못 닿는다 (다른 Wi-Fi. 실제로 이걸로 한 번 막혔다)
#   - 닿기는 하는데 push-to-start 토큰이 없다 (Live Activity 꺼짐, 권한)
#
# `last_seen` 은 인증된 요청이 한 건이라도 오면 채워진다. 그게 도달성의 증거다.
# 예전에는 `device_token` 을 봤는데 그건 **별개 토큰**이라, 기기가 잘 닿고 있는데도
# "못 닿는다" 고 죽었다. 한 번 이걸로 헛다리를 짚었다.
for i in "${!DEVICES[@]}"; do
  who="${WATCHER_NAMES[$i]}"
  acct="${WATCHER_IDS[$i]}"
  reached=0
  for _ in $(seq 1 25); do
    seen=$(status "${WATCHER_TOKENS[$i]}" lastSeen)
    [ -n "$seen" ] && [ "$seen" != "null" ] && { reached=1; break; }
    sleep 1
  done
  [ "$reached" = "1" ] || die "$who 기기가 서버에 못 닿는다. 25초 동안 요청이 한 건도 없었다.

     APNs 알림은 애플 서버에서 폰으로 가니까 카드는 뜰 수 있다. 하지만 폰이
     맥으로 토큰을 못 보내면 갱신은 영영 안 온다. 카드가 처음 값에서 멈춘다.

     그 기기 설정 → Wi-Fi 를 봐라. 맥과 같은 네트워크여야 한다($MAC_HOST / $(ipconfig getifaddr en0 2>/dev/null))."
  ok "$who 서버 도달 확인"

  token=""
  for _ in $(seq 1 25); do
    [ "$(status "${WATCHER_TOKENS[$i]}" startToken)" = "true" ] && { token="있음"; break; }
    sleep 1
  done
  [ -n "$token" ] || die "$who 는 서버에 닿는데 push-to-start 토큰이 없다.
     기기 설정 → 귀가마중 → 실시간 현황(Live Activities) 이 켜져 있는지 봐라.
     앱 재설치하면 토큰이 바뀐다는 것도 기억해라."
  ok "$who push-to-start 토큰 등록됨"
done

# ------------------------------------------------------------------ 4. 페어링

step "페어링 — 승인 주체는 귀가자다"
# 지난 실행의 연결을 **기기 쪽에서** 끊는다.
#
# 예전에는 귀가자 쪽에서만 끊었다. 그런데 귀가자는 실행마다 새로 만들어지니 끊을
# 것이 없고, 연결은 계속 기기 쪽에 쌓였다. 실제로 폰의 "내가 지켜보는 사람" 에
# **"아빠, 아빠, 아빠, 아빠, 아빠"** 가 여섯 줄 쌓였다 — 전부 다른 계정인데
# 이름이 같아 사람이 구분할 수도 없었다.
#
# 해제는 양쪽 다 가능하다. 한쪽만 가능하면 다른 쪽이 묶이거나 통제를 잃는다.
for i in "${!DEVICES[@]}"; do
  for OLD in $(as "${WATCHER_TOKENS[$i]}" "$BACKEND_LOCAL/pair/watching" \
               | grep -oE '"accountId": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/'); do
    as "${WATCHER_TOKENS[$i]}" -X DELETE "$BACKEND_LOCAL/pair/link/$OLD" >/dev/null
    ok "${WATCHER_NAMES[$i]} 의 지난 연결 해제 $OLD"
  done
done

CODE=$(as "$TRAVELER_TOKEN" -X POST "$BACKEND_LOCAL/pair/invite" \
  -H 'Content-Type: application/json' \
  -d '{"travelerName":"아빠"}' | sed -n 's/.*"code": *"\([^"]*\)".*/\1/p')
[ -n "$CODE" ] || die "초대 코드를 못 받았다."
ok "초대 코드 $CODE"

for i in "${!DEVICES[@]}"; do
  who="${WATCHER_NAMES[$i]}"
  as "${WATCHER_TOKENS[$i]}" -X POST "$BACKEND_LOCAL/pair/accept" \
    -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\",\"name\":\"$who\"}" >/dev/null
  ok "$who 연결"
done

LINKED=$(as "$TRAVELER_TOKEN" "$BACKEND_LOCAL/pair/watchers" | grep -o accountId | wc -l | tr -d ' ')
[ "$LINKED" = "${#DEVICES[@]}" ] || die "연결된 가족이 $LINKED 명이다. ${#DEVICES[@]} 명이어야 한다."
ok "가족 $LINKED 명 연결 확인"

# ------------------------------------------------------------------ 5. 세션

# ------------------------------------------------------------------ 5b. 경로로 돈다

if [ -n "$ROUTE" ]; then
  step "저장된 경로로 귀가 — 카드가 구간과 지연을 말한다"
  echo "  도착예정은 저장된 소요시간에서 나온다. 위치는 어느 구간인지와 지연만 잰다."
  echo
  echo "  ── 기기 잠금화면을 보고 있어라 ──"
  echo "  '아빠이 집으로 출발했어요' 로 카드가 뜨고, 그 뒤 한 줄이 이렇게 바뀐다:"
  echo "    도보 · 출발역.은행앞까지 6분"
  echo "    버스 · 환승로터리까지 8분"
  echo "    지하철 · 풍산역까지 30분"
  echo "    버스 · 아파트단지까지 9분"
  echo
  echo "  액티비티 갱신 토큰은 카드가 뜬 뒤 30초쯤에 올라온다. 그전 몇 줄은"
  echo "  카드에 반영되지 않는다 — 폰이 서버로 토큰을 보내야 갱신이 가능해서다."
  echo

  SESSION_FILE="${TMPDIR:-/tmp}/homecoming-e2e-session"
  python3 -u Tools/route-play.py "$ROUTE" --register --speed "$PLAY_SPEED" \
    --backend "$BACKEND_LOCAL" --token "$TRAVELER_TOKEN" --no-end \
    --session-out "$SESSION_FILE"
  PLAY_STATUS=$?

  # route-play 가 만든 세션. 활성 세션 조회로는 못 찾는다 — 도착하면 닫히기 때문이다.
  SESSION=$(cat "$SESSION_FILE" 2>/dev/null)
  step "결과"
  echo "  세션      $SESSION"
  echo "  가족 기기 ${#DEVICES[@]} 대"
  # **닿은 갱신 횟수를 본다.** 예전에는 남아 있는 액티비티 수를 셌는데, 도착하면
  # 서버가 그걸 정리하므로 통과한 실행에서도 항상 0 이 나왔다. 통과가 실패처럼
  # 보이는 판정은 곧 아무도 안 믿는 판정이 된다.
  SENT=$(session_field updatesSent)
  if [ -n "$SENT" ] && [ "$SENT" -gt 0 ] 2>/dev/null; then
    ok "가족 화면에 갱신 $SENT 번 닿았다"
  else
    bad "갱신이 한 번도 닿지 않았다. 카드는 떠도 첫 값에서 멈춘다."
  fi
  echo
  echo "  눈으로 확인해야 하는 것:"
  echo "   1. 카드 한 줄이 구간 이름과 남은 시간으로 바뀌었는가"
  echo "   2. 그 문구가 한 번도 뒤로 가지 않았는가"
  echo "   3. 환승 대기 뒤에 'N분 지연' 이 붙었는가"
  echo "   4. 도착예정 시각이 흔들리지 않았는가 (지하철 구간에서도)"
  [ "$KEEP_DB" = "0" ] && as "$TRAVELER_TOKEN" -X POST "$BACKEND_LOCAL/session/$SESSION/end" \
    -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
  exit "$PLAY_STATUS"
fi

step "귀가 시작 — 이 순간 가족 기기에 알림이 떠야 한다"
SESSION=$(as "$TRAVELER_TOKEN" -X POST "$BACKEND_LOCAL/session/start" \
  -H 'Content-Type: application/json' \
  -d "{\"travelerName\":\"아빠\",\"home\":{\"lat\":$HOME_LAT,\"lon\":$HOME_LON,\"name\":\"집\",\"arrivalRadius\":120}}" \
  | sed -n 's/.*"sessionId": *"\([^"]*\)".*/\1/p')
[ -n "$SESSION" ] || die "세션을 못 만들었다."
ok "세션 $SESSION"

echo
echo "  ── 지금 기기 잠금화면과 다이나믹 아일랜드를 봐라 ──"
echo "  '아빠이 집으로 출발했어요' 알림과 카드가 떠 있어야 한다."
echo

# 카드가 뜨는 것과 카드가 갱신되는 것은 다른 경로다.
#   카드 띄우기 = APNs(애플) → 폰.          폰이 맥에 닿을 필요가 없다.
#   카드 갱신   = 폰 → 맥(액티비티 토큰) → APNs → 폰.
# 그래서 토큰을 안 올린 기기는 카드가 떠 있는데 처음 값에서 멈춘다.
# 실측 31초. 넉넉히 기다린다.
step "액티비티 토큰 회수 대기 — 갱신이 갈 기기를 정한다"
for _ in $(seq 1 60); do
  STARTED=$(session_field activities)
  [ "$STARTED" = "${#DEVICES[@]}" ] && break
  sleep 1
done
if [ "$STARTED" = "${#DEVICES[@]}" ]; then
  ok "기기 $STARTED 대 전부 갱신 대상"
else
  bad "$STARTED/${#DEVICES[@]} 대만 토큰을 올렸다. 나머지 카드는 처음 값에서 멈춘다."
fi

# ------------------------------------------------------------------ 6. 접근

step "집으로 접근 — 단계가 뒤로 가지 않는지 본다"
# 집에서 북쪽으로 떨어진 지점들. 1도 ≈ 111320m.
for METERS in 4000 2800 1600 700 300 80; do
  LAT=$(awk -v h="$HOME_LAT" -v m="$METERS" 'BEGIN{printf "%.6f", h + m/111320}')
  as "$TRAVELER_TOKEN" -X POST "$BACKEND_LOCAL/session/$SESSION/location" \
    -H 'Content-Type: application/json' \
    -d "{\"lat\":$LAT,\"lon\":$HOME_LON,\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >/dev/null
  SNAP=$(as "$TRAVELER_TOKEN" "$BACKEND_LOCAL/session/$SESSION")
  STAGE=$(echo "$SNAP" | field stage)
  REMAIN=$(echo "$SNAP" | field remainingMeters)
  LIVE=$(echo "$SNAP" | field activities)
  printf '  %5sm 전송 → 단계 %-10s 남은거리 %-6sm 갱신 %s/%s대\n' \
    "$METERS" "$STAGE" "$REMAIN" "$LIVE" "${#DEVICES[@]}"
  sleep 4
done

STAGE=$(session_field stage)
[ "$STAGE" = "arrived" ] && ok "도착 판정" || bad "단계가 $STAGE 다. arrived 여야 한다(반경 120m, 하한 100m)."

# ------------------------------------------------------------------ 7. 종료

step "종료 — 도착 화면을 20초 보여 준 뒤 서버가 end 를 쏜다"
echo "  다이나믹 아일랜드는 end 를 받는 순간 알림을 치운다. 그 20초가 가족이 보는 시간이다."
for i in $(seq 24 -1 1); do printf '\r  %2d초...' "$i"; sleep 1; done; printf '\r          \r'

LEFT=$(session_field activities)
[ "$LEFT" = "0" ] && ok "액티비티 정리됨" || bad "액티비티 $LEFT 개가 남아 있다."

FIXES=$(session_field fixes)
[ "$FIXES" = "0" ] && ok "위치 이력 전부 삭제됨" || bad "위치가 $FIXES 건 남아 있다(도착 시 0이어야 한다)."

# ------------------------------------------------------------------ 정리

step "결과"
echo "  세션      $SESSION"
echo "  가족 기기 ${#DEVICES[@]} 대"
echo
echo "  눈으로 확인해야 하는 것:"
echo "   1. 귀가 시작 알림이 잠금화면에 떴는가"
echo "   2. 카드에 남은거리·도착예정이 보였는가"
echo "   3. 접근하면서 값이 갱신됐는가"
echo "   4. 축소(다이나믹 아일랜드)와 확장 화면의 카운트다운이 같았는가"
[ "${#DEVICES[@]}" -ge 2 ] && echo "   5. 두 기기가 같은 값을 보여 줬는가"

if [ "$KEEP_DB" = "0" ]; then
  as "$TRAVELER_TOKEN" -X POST "$BACKEND_LOCAL/session/$SESSION/end" \
    -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true

  # **올린 경로도 치운다.** `--route` 로 돌면 `route-play --register` 가 경로를
  # 서버에 저장하는데, `purge()` 는 경로를 건드리지 않아서 실행마다 한 줄이
  # 영구히 쌓였다. 배포 서버로 돌리면 그게 배포 DB 에 남는다 — 게다가 경로에는
  # 집 좌표가 들어 있다.
  #
  # 실행이 끝나면 그 토큰은 사라지므로 **여기서 지우지 않으면 영영 못 지운다.**
  # 실제로 2026-08-19 에 한 줄을 그렇게 남겼고 되찾을 방법이 없었다.
  #
  # 귀가자 계정은 실행마다 새로 만든 임시 계정이라 그 계정의 경로를 전부 지워도
  # 안전하다. 가족 기기 계정(`$KEY_DIR`)은 건드리지 않는다 — 그쪽 push-to-start
  # 토큰을 유지해야 다음 실행이 된다.
  for RID in $(as "$TRAVELER_TOKEN" "$BACKEND_LOCAL/route" 2>/dev/null \
                 | grep -o '"routeId": *"[^"]*"' | sed 's/.*"routeId": *"//;s/"//'); do
    as "$TRAVELER_TOKEN" -X DELETE "$BACKEND_LOCAL/route/$RID" >/dev/null 2>&1 \
      && ok "경로 $RID 삭제" || bad "경로 $RID 삭제 실패"
  done

  # 이 실행이 만든 페어링도 끊는다. 가족 계정은 다음 실행에도 쓰지만, 링크는
  # 실행마다 새 귀가자를 향해 다시 만들어지므로 쌓인다.
  for i in "${!DEVICES[@]}"; do
    as "${WATCHER_TOKENS[$i]}" -X DELETE "$BACKEND_LOCAL/pair/link/$TRAVELER" \
      >/dev/null 2>&1 || true
  done
  ok "이 실행이 만든 페어링 해제"
fi
