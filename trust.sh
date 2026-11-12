#!/usr/bin/env bash
# Proof script for Zode warm snapshots. Tokens are fake ("zodeplant_" plus the
# run id); this script never prints a token, only where one was found.
set -u
asroot() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }
homes="/home/runner /root"
event="${GITHUB_EVENT_NAME:-?}"
head=$(python3 -c 'import json,os; e=json.load(open(os.environ["GITHUB_EVENT_PATH"])); print(((e.get("pull_request") or {}).get("head") or {}).get("repo",{}).get("full_name",""))' 2>/dev/null)
kind=default
case "$event" in pull_request*) if [ "${head,,}" = "${GITHUB_REPOSITORY,,}" ]; then kind=pr; else kind=fork; fi;; esac
[ "$kind" = default ] && [ "${GITHUB_REF:-}" != "refs/heads/main" ] && kind=branch

inspect() {
  echo "event=$event kind=$kind run=$GITHUB_RUN_ID user=$(id -un) home=$HOME"
  if grep -qs " /mnt/zode-warm " /proc/mounts; then echo "warm_disk=mounted"; else echo "warm_disk=none"; fi
  for h in $homes; do
    m=$(asroot cat "$h/.cache/zode-trust/marker" 2>/dev/null || true)
    p=$(asroot cat "$h/.cache/zode-trust/poison" 2>/dev/null || true)
    echo "marker[$h]=${m:-none}"
    echo "poison[$h]=${p:-none}"
  done
  # every planted token from any earlier run, anywhere a job could read it
  leaks=$(asroot grep -rlI --exclude-dir=containerd --exclude-dir=docker -e zodeplant_ \
    /home /root /opt/zode-runner* /tmp /var/lib/zode-ci /mnt/zode-warm 2>/dev/null | grep -v "/trust.sh$" | sort -u)
  n=$(printf '%s' "$leaks" | grep -c . || true)
  echo "planted_tokens_found=$n"
  [ -z "$leaks" ] || printf '%s\n' "$leaks" | sed 's/^/LEAK /'
  if [ "$kind" = fork ] && grep -qs "default" <(for h in $homes; do asroot cat "$h/.cache/zode-trust/marker" 2>/dev/null; done); then
    echo "FAIL: a fork pull request read a file a default-branch job wrote"; exit 1
  fi
  if [ "$kind" = default ] && [ "$n" != 0 ]; then echo "FAIL: planted tokens survived into this job"; exit 1; fi
  if [ "$kind" = default ] && for h in $homes; do asroot cat "$h/.cache/zode-trust/poison" 2>/dev/null; done | grep -q .; then
    echo "FAIL: a pull request changed what this default-branch job sees"; exit 1
  fi
  echo "PASS inspect ($kind)"
}

mark() {
  tok="zodeplant_${GITHUB_RUN_ID}"
  if [ "$kind" = default ]; then
    for h in $homes; do
      asroot mkdir -p "$h/.cache/zode-trust" "$h/.docker" "$h/.aws" "$h/.ssh" "$h/.config/gh" "$h/.config/zode-trust-secret"
      echo "default run $GITHUB_RUN_ID" | asroot tee "$h/.cache/zode-trust/marker" >/dev/null
      for f in .docker/config.json .npmrc .netrc .aws/credentials .ssh/id_zode .config/gh/hosts.yml .config/zode-trust-secret/token; do
        echo "$tok" | asroot tee "$h/$f" >/dev/null
      done
    done
    echo "$tok" > "${RUNNER_TEMP:-/tmp}/zode-plant"
    for d in /opt/zode-runner*; do
      asroot mkdir -p "$d/_diag"
      echo "$tok" | asroot tee "$d/_diag/zode-plant.log" "$d/.credentials_zodeplant" "$d/.runner_zodeplant" >/dev/null
    done
    git config --add http.https://github.com/.extraheader "AUTHORIZATION: basic $tok"
    echo "planted a token in every scrubbed path and marked the warm state (run $GITHUB_RUN_ID)"
  else
    for h in $homes; do
      asroot mkdir -p "$h/.cache/zode-trust"
      echo "$kind run $GITHUB_RUN_ID" | asroot tee "$h/.cache/zode-trust/poison" "$h/.cache/zode-trust/marker" >/dev/null
    done
    echo "tried to poison the warm state as $kind (run $GITHUB_RUN_ID)"
  fi
}

"$@"
