#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  . "$SCRIPT_DIR/.env"
  set +a
fi

: "${MQTT_HOST:?MQTT_HOST is required}"
: "${MQTT_PORT:=1883}"
: "${MQTT_TOPIC:=sensors/2jciebu/state}"
: "${DEVICE_ID:=2jciebu_01}"

MQTT_AUTH=""
if [ -n "${MQTT_USERNAME:-}" ]; then
  MQTT_AUTH="-u ${MQTT_USERNAME} -P ${MQTT_PASSWORD:-}"
fi

# metric_key|表示名|unit|device_class
# unit/device_classが未確定・要検証のものは空欄にしてある(README参照)。
METRICS='
temperature|Temperature|°C|temperature
humidity|Humidity|%|humidity
light|Ambient Light|lx|illuminance
barometric|Barometric Pressure|hPa|pressure
noise|Sound Noise|dB|
etvoc|eTVOC|ppb|
eco2|eCO2|ppm|carbon_dioxide
discomfort|Discomfort Index||
heat|Heat Stroke Index|°C|
vibration|Vibration Information||
si|SI Value|kine|
pga|PGA|gal|
seismic|Seismic Intensity||
'

echo "$METRICS" | while IFS='|' read -r key name unit device_class; do
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

  # shellcheck disable=SC2086
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" $MQTT_AUTH -r \
    -t "homeassistant/sensor/${DEVICE_ID}/${key}/config" \
    -m "$PAYLOAD"
  echo "published discovery config for ${key}"
done
