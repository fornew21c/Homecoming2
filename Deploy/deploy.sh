#!/bin/bash
#
# 서버를 올린다.
#
#   Deploy/deploy.sh homecoming.example.com
#   Deploy/deploy.sh homecoming.example.com --user ubuntu
#
# 처음 한 번은 `Deploy/README.md` 의 "처음 준비" 를 먼저 해야 한다. 이 스크립트는
# 코드를 바꿔 넣고 다시 띄우는 것만 한다 — 계정 만들기, 비밀값 넣기, 인증서는
# 한 번만 하는 일이라 자동화하지 않았다. 자동화하면 잘못 돌 때 무엇이 잘못됐는지
# 알기 어렵다.
#
# **DB 는 건드리지 않는다.** /var/lib/homecoming 은 rsync 대상이 아니다.
#
set -euo pipefail

HOST="${1:-}"
SSH_USER="ubuntu"
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --user) SSH_USER="$2"; shift 2 ;;
    *) echo "모르는 옵션: $1" >&2; exit 2 ;;
  esac
done

[ -n "$HOST" ] || { echo "사용법: Deploy/deploy.sh <호스트> [--user <계정>]" >&2; exit 2; }

cd "$(dirname "$0")/.."

step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

REMOTE="$SSH_USER@$HOST"

step "문법 확인 — 서버에 올리기 전에"
python3 -m py_compile Server/homecoming_server.py || die "문법 오류가 있다."
ok "python3 -m py_compile 통과"

step "코드 전송"
# 코드만 간다. DB 도, 비밀값도, __pycache__ 도 가지 않는다.
rsync -az --delete \
  --exclude '__pycache__' \
  --exclude '*.sqlite*' \
  --exclude '.env.local' \
  Server/homecoming_server.py \
  "$REMOTE:/tmp/homecoming_server.py" || die "전송 실패."
ok "서버 코드 전송"

step "바꿔 넣고 다시 띄우기"
ssh "$REMOTE" bash -euo pipefail <<'SCRIPT'
  sudo install -o homecoming -g homecoming -m 0644 \
    /tmp/homecoming_server.py /opt/homecoming/homecoming_server.py
  rm -f /tmp/homecoming_server.py
  sudo systemctl restart homecoming
SCRIPT
ok "restart 완료"

step "살아 있는지 확인"
# 로컬에서 HTTPS 로 확인한다. 서버 안에서 127.0.0.1 을 찔러 보는 것과 다르다 —
# 확인하려는 것은 "앱이 닿을 수 있는가" 이고, 그 경로에는 인증서와 프록시가 있다.
for _ in $(seq 1 20); do
  HEALTH=$(curl -sS --max-time 5 "https://$HOST/health" 2>/dev/null || true)
  [ -n "$HEALTH" ] && break
  sleep 1
done
[ -n "$HEALTH" ] || die "https://$HOST/health 가 응답하지 않는다.
     sudo journalctl -u homecoming -n 50
     sudo journalctl -u caddy -n 50"
ok "health $HEALTH"

case "$HEALTH" in
  *'"apns": true'*|*'"apns":true'*) ok "APNs 설정됨" ;;
  *) die "APNs 미설정. /etc/homecoming.env 의 HOMECOMING_APNS_* 를 확인해라.
     이게 없으면 서버는 돌지만 가족 기기에 알림이 한 건도 가지 않는다." ;;
esac

# 인증 없이 열려 있는 곳이 늘어나지 않았는지 본다. 배포마다 확인할 값이다.
step "인증이 걸려 있는지"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://$HOST/route" || echo 000)
[ "$CODE" = "401" ] || die "토큰 없이 /route 가 $CODE 를 준다. 401 이어야 한다."
ok "토큰 없는 요청은 401"

printf '\n\033[32m배포 완료 — https://%s\033[0m\n' "$HOST"
printf '앱의 App/Info.plist 의 HomecomingBackendBaseURL 이 이 주소여야 한다.\n'
