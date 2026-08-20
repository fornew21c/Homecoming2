#!/bin/sh
#
# 컨테이너 진입점.
#
# **볼륨은 root 소유로 마운트된다.** 그래서 이미지에서 곧장 비루트로 내려가면
# 서버가 `/data` 에 DB 를 못 만들고 `unable to open database file` 로 죽는다.
# 실제로 첫 배포가 이걸로 헬스체크에서 떨어졌다.
#
# 그래서 root 로 시작해 마운트 지점 하나만 넘겨주고 곧바로 권한을 내려놓는다.
# 서버 프로세스 자체는 root 로 돌지 않는다 — 하는 일이 소켓 하나와 파일 하나뿐이라
# root 일 이유가 없고, 이 서버는 사람들의 실시간 위치를 다룬다.
set -eu

DB="${HOMECOMING_DB:-/app/homecoming.sqlite}"
DIR=$(dirname "$DB")

mkdir -p "$DIR"
chown -R homecoming:homecoming "$DIR"

exec setpriv --reuid=homecoming --regid=homecoming --clear-groups \
    python3 -u /app/homecoming_server.py --host 0.0.0.0
