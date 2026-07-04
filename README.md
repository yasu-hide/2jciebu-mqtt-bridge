# 2jciebu-mqtt-bridge

`2jciebu-exporter`の`/metrics`をcronで1分ごとにポーリングし、センサー値をMQTTにJSONでpublishするブリッジ。Home Assistant向けのMQTT Discovery設定も一度だけ発行する。

常駐デーモンを持たない設計（cronのワンショット実行のみ）のため、メモリの小さい機体でも安心して動かせる。

## 前提

- 稼働中の`2jciebu-exporter`（同一ホスト、`http://localhost:8000/metrics`が読める）
- MQTTブローカー（同一LAN上、認証は任意）
- Ubuntu/Debian系(apt)、cron、`curl`（標準搭載）

## 導入手順

```bash
sudo apt-get install -y mosquitto-clients   # curl/awk/greploggerは標準搭載のため追加インストール不要

sudo mkdir -p /opt/2jciebu-mqtt-bridge
sudo cp poll-and-publish.sh discovery/publish-discovery.sh /opt/2jciebu-mqtt-bridge/
sudo chmod +x /opt/2jciebu-mqtt-bridge/*.sh

sudo cp etc/cron.d.2jciebu-mqtt-bridge /etc/cron.d/2jciebu-mqtt-bridge
sudo chmod 600 /etc/cron.d/2jciebu-mqtt-bridge   # MQTT_PASSWORDを含むため権限を絞る
sudo "$EDITOR" /etc/cron.d/2jciebu-mqtt-bridge   # MQTT_HOST等の値を編集
```

Home Assistant向けMQTT Discoveryの登録（初回のみ、冪等なので何度実行してもよい）:

```bash
sudo MQTT_HOST=<broker> MQTT_TOPIC=sensors/2jciebu/state DEVICE_ID=2jciebu_01 \
  /opt/2jciebu-mqtt-bridge/discovery/publish-discovery.sh
```

## 設定ファイル（`/etc/cron.d/2jciebu-mqtt-bridge`の環境変数）

| 変数 | デフォルト | 説明 |
|---|---|---|
| `EXPORTER_URL` | `http://localhost:8000/metrics` | exporterのmetricsエンドポイント。exporter側の`SERVER_HTTP_PORT`と一致させること |
| `MQTT_HOST` | (必須) | MQTTブローカーのホスト |
| `MQTT_PORT` | `1883` | |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | 空 | 空なら認証なしで接続 |
| `MQTT_TOPIC` | `sensors/2jciebu/state` | publish先トピック |
| `DEVICE_ID` | `2jciebu_01` | (Discoveryスクリプト用) Home Assistant上のデバイス識別子。複数センサーを増設する場合はホストごとに一意な値にすること |

ポーリング間隔はcronのスケジュール行（既定で毎分=60秒間隔）で決まる。変更したい場合は`/etc/cron.d/2jciebu-mqtt-bridge`の`* * * * *`部分を編集する。

## publishされるJSONの例

```json
{"sensor_omron_temperature":25.3,"sensor_omron_humidity":48.0,"sensor_omron_light":350.5, ...}
```

キー名は`sensor_omron_`で始まる既知の13メトリクスのみ（許可リスト方式）。exporter側にこれ以外のメトリクスが増えても無視され、該当行が1件もマッチしなかった場合はpublishをスキップしてログに警告を残す（無音のデータ欠落を避けるため）。

## トラブルシューティング

ログは`journalctl`または`/var/log/syslog`に`2jciebu-mqtt-bridge`タグで出力される。

| ログメッセージ | 原因 | 対処 |
|---|---|---|
| `MQTT_HOST is required` | `/etc/cron.d/2jciebu-mqtt-bridge`に`MQTT_HOST`が設定されていない | 値を設定する |
| `fetch failed: ... unreachable` | exporterが停止中/到達不能 | exporterのサービス状態・`EXPORTER_URL`を確認。次回のcron実行(最大1分後)で自動的に再試行される |
| `warning: 0 metrics parsed ...` | exporter側のメトリクス形状が変わり、許可リストに一致する行がなくなった | exporterの`/metrics`を確認し、必要ならこのスクリプトの許可リストを更新する |
| `mosquitto_pub failed: ... unreachable or auth error` | MQTTブローカーに到達できない、または認証エラー | ブローカーの状態・`MQTT_HOST`/`MQTT_PORT`/認証情報を確認。次回のcron実行で自動的に再試行される |

何も出力がない（cronが動いていない）場合は`grep 2jciebu-mqtt-bridge /etc/cron.d/2jciebu-mqtt-bridge`でファイルの権限(600)・書式を確認する。

## MQTT Discoveryで登録したエンティティを削除したい場合

同じトピックへ空メッセージをretainでpublishすると、Home Assistant側の該当エンティティが削除される:

```bash
mosquitto_pub -h <broker> -r -t "homeassistant/sensor/<device_id>/<metric>/config" -m ""
```

## セキュリティ・制約に関する注意

- MQTTブローカーは信頼できるLAN上にある前提で、TLS対応は行っていない。ブローカーをLAN外に公開する場合は再検討すること。
- センサー本体の故障（`2jciebu-exporter`側の`SensorSerialError`）が起きた場合、exporterは直前の値をHTTP 200で返し続ける。本ブリッジ単体では新鮮な値と古い値を区別できないため、古い値をそのままpublishし続ける可能性がある。

## ローカルでの動作確認

```bash
curl -s http://localhost:8000/metrics | grep sensor_omron   # exporterが値を返しているか確認
mosquitto_sub -h <broker> -t sensors/2jciebu/state -v        # 別ターミナルで購読
sudo MQTT_HOST=<broker> /opt/2jciebu-mqtt-bridge/poll-and-publish.sh   # 手動実行して即時確認
```
