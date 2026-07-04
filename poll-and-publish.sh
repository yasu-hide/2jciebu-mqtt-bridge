#!/bin/sh
set -eu

: "${EXPORTER_URL:=http://localhost:8000/metrics}"
: "${MQTT_HOST:?MQTT_HOST is required}"
: "${MQTT_PORT:=1883}"
: "${DEVICE_ID:=2jciebu_01}"
# 複数デバイス増設時にトピックが衝突しないよう、既定でDEVICE_IDを名前空間に含める。
# (.envのEnvironmentFile=は${VAR}展開をしないため、ここで実際のシェル展開を行う)
: "${MQTT_TOPIC:=sensors/2jciebu/${DEVICE_ID}/state}"

METRICS=$(curl -sf --max-time 5 "$EXPORTER_URL") || {
  echo "fetch failed: ${EXPORTER_URL} unreachable" >&2
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
  echo "warning: 0 metrics parsed from ${EXPORTER_URL} (allowlistに一致する行なし、exporter側の形状変化の可能性)" >&2
  exit 0
fi

MQTT_AUTH=""
if [ -n "${MQTT_USERNAME:-}" ]; then
  MQTT_AUTH="-u ${MQTT_USERNAME} -P ${MQTT_PASSWORD:-}"
fi

# mosquitto_pub(このホストのバージョン1.6.9で確認済み)は認証拒否等の
# CONNECT失敗時でも終了コード0を返すため、終了コードは信用せず、-dの出力に
# 実際に現れるCONNACK reason codeで成否を判定する(0=成功、それ以外=失敗)。
# shellcheck disable=SC2086
MQTT_OUTPUT=$(mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" $MQTT_AUTH -q 1 -r -t "$MQTT_TOPIC" -m "$JSON" -d 2>&1) || true

if ! printf '%s\n' "$MQTT_OUTPUT" | grep -q 'CONNACK (0)'; then
  echo "mosquitto_pub failed: broker ${MQTT_HOST}:${MQTT_PORT} unreachable or auth error" >&2
  printf '%s\n' "$MQTT_OUTPUT" >&2
  exit 1
fi

echo "published to ${MQTT_TOPIC}"
