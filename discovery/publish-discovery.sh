#!/bin/sh
set -eu

: "${MQTT_HOST:?MQTT_HOST is required}"
: "${MQTT_PORT:=1883}"
: "${DEVICE_ID:=2jciebu_01}"
# poll-and-publish.shと同じ導出方法。ずれるとstate_topicの不一致でHA側が
# 値を受け取れなくなる(要:両スクリプトで常に同一のデフォルト式を保つ)。
: "${MQTT_TOPIC:=sensors/2jciebu/${DEVICE_ID}/state}"

MQTT_AUTH=""
if [ -n "${MQTT_USERNAME:-}" ]; then
  MQTT_AUTH="-u ${MQTT_USERNAME} -P ${MQTT_PASSWORD:-}"
fi

# metric_key|表示名|unit|device_class
# device_classはOMRON公式データシート(CDSC-016)のOutput rangeで単位・意味を確認した
# うえで設定。discomfort/si/pga/seismicはデータシート上も無単位またはHA未対応の単位
# (kine/gal)のため対応するdevice_classがHAに存在せず空欄。heatは単位こそdegCだが
# 気温そのものではない計算指標のためtemperatureは付与しない。vibrationは意味的には
# enum相当だが、数値→文字列enumへの型変更が既存の履歴/automationに与える影響を
# 精査してから別途対応する(空欄のまま)。
METRICS='
temperature|Temperature|°C|temperature
humidity|Humidity|%|humidity
light|Ambient Light|lx|illuminance
barometric|Barometric Pressure|hPa|pressure
noise|Sound Noise|dB|sound_pressure
etvoc|eTVOC|ppb|volatile_organic_compounds_parts
eco2|eCO2|ppm|carbon_dioxide
discomfort|Discomfort Index||
heat|Heat Stroke Index|°C|
vibration|Vibration Information||
si|SI Value|kine|
pga|PGA|gal|
seismic|Seismic Intensity||
'

FAILED=0

# echo "$METRICS" | while ... はwhileがサブシェルで動くためFAILEDの更新が
# ループ外に伝わらない。ヒアドキュメントでリダイレクトすることで同一シェル
# 内でループを実行する。
while IFS='|' read -r key name unit device_class; do
  [ -z "$key" ] && continue

  device_class_json=""
  if [ -n "$device_class" ]; then
    device_class_json=",\"device_class\":\"${device_class}\",\"state_class\":\"measurement\""
  fi
  unit_json=""
  if [ -n "$unit" ]; then
    unit_json=",\"unit_of_measurement\":\"${unit}\""
  fi

  PAYLOAD=$(cat <<EOF
{"name":"${name}","unique_id":"${DEVICE_ID}_${key}","state_topic":"${MQTT_TOPIC}","value_template":"{{ value_json.sensor_omron_${key} }}"${unit_json}${device_class_json},"device":{"identifiers":["${DEVICE_ID}"],"name":"2JCIE-BU (${DEVICE_ID})","manufacturer":"OMRON","model":"2JCIE-BU"}}
EOF
)

  # mosquitto_pub(1.6.9で確認済み)は認証拒否でも終了コード0を返すため、
  # -dの出力の実際のCONNACK reason codeで成否を判定する。
  # shellcheck disable=SC2086
  MQTT_OUTPUT=$(mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" $MQTT_AUTH -r \
    -t "homeassistant/sensor/${DEVICE_ID}/${key}/config" \
    -m "$PAYLOAD" -d 2>&1) || true

  if printf '%s\n' "$MQTT_OUTPUT" | grep -q 'CONNACK (0)'; then
    echo "published discovery config for ${key}"
  else
    echo "failed to publish discovery config for ${key}: broker ${MQTT_HOST}:${MQTT_PORT} unreachable or auth error" >&2
    printf '%s\n' "$MQTT_OUTPUT" >&2
    FAILED=1
  fi
done <<EOF
$METRICS
EOF

if [ "$FAILED" -ne 0 ]; then
  echo "one or more discovery configs failed to publish" >&2
  exit 1
fi
