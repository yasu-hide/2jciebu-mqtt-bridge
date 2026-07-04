#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  . "$SCRIPT_DIR/.env"
  set +a
fi

: "${EXPORTER_URL:=http://localhost:8000/metrics}"
: "${MQTT_HOST:?MQTT_HOST is required}"
: "${MQTT_PORT:=1883}"
: "${MQTT_TOPIC:=sensors/2jciebu/state}"

TAG=2jciebu-mqtt-bridge

METRICS=$(curl -sf --max-time 5 "$EXPORTER_URL") || {
  logger -t "$TAG" "fetch failed: ${EXPORTER_URL} unreachable"
  exit 1
}

# 既知の13メトリクス名のみを明示allowlist(exporter側の形状変化を無音で無視しないため)
JSON=$(printf '%s\n' "$METRICS" | awk '
  BEGIN {
    n = split("temperature humidity light barometric noise etvoc eco2 discomfort heat vibration si pga seismic", suf)
    for (i = 1; i <= n; i++) allow["sensor_omron_" suf[i]] = 1
  }
  /^#/ { next }
  NF == 2 && ($1 in allow) {
    printf "%s\"%s\":%s", (c++ ? "," : "{"), $1, $2
  }
  END { print (c ? "}" : "{}") }
')

if [ "$JSON" = "{}" ]; then
  logger -t "$TAG" "warning: 0 metrics parsed from ${EXPORTER_URL} (allowlistに一致する行なし、exporter側の形状変化の可能性)"
  exit 0
fi

MQTT_AUTH=""
if [ -n "${MQTT_USERNAME:-}" ]; then
  MQTT_AUTH="-u ${MQTT_USERNAME} -P ${MQTT_PASSWORD:-}"
fi

# shellcheck disable=SC2086
mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" $MQTT_AUTH -q 1 -r -t "$MQTT_TOPIC" -m "$JSON" || {
  logger -t "$TAG" "mosquitto_pub failed: broker ${MQTT_HOST}:${MQTT_PORT} unreachable or auth error"
  exit 1
}

logger -t "$TAG" "published to ${MQTT_TOPIC}"
