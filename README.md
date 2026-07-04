# 2jciebu-mqtt-bridge

`2jciebu-exporter`の`/metrics`をsystemd-timerで1分ごとにポーリングし、センサー値をMQTTにJSONでpublishするブリッジ。Home Assistant向けのMQTT Discovery設定も一度だけ発行する。

常駐デーモンを持たない設計（systemd oneshotサービス+timerによる定期実行のみ）のため、メモリの小さい機体でも安心して動かせる。

## 前提

- 稼働中の`2jciebu-exporter`（同一ホスト、`http://localhost:8000/metrics`が読める）
- MQTTブローカー（同一LAN上、認証は任意）
- systemd搭載のLinux（Ubuntu/Debian系）、`curl`（標準搭載）

## 導入手順

```bash
sudo apt-get install -y mosquitto-clients   # curl/awkは標準搭載のため追加インストール不要

sudo mkdir -p /opt/2jciebu-mqtt-bridge
sudo cp poll-and-publish.sh /opt/2jciebu-mqtt-bridge/
sudo cp -r discovery /opt/2jciebu-mqtt-bridge/
sudo chmod +x /opt/2jciebu-mqtt-bridge/poll-and-publish.sh /opt/2jciebu-mqtt-bridge/discovery/publish-discovery.sh

sudo cp .env.example /opt/2jciebu-mqtt-bridge/.env
sudo chmod 600 /opt/2jciebu-mqtt-bridge/.env   # MQTT_PASSWORDを含むため権限を絞る
sudo "$EDITOR" /opt/2jciebu-mqtt-bridge/.env   # MQTT_HOST等の値を編集

sudo cp systemd/2jciebu-mqtt-bridge.service systemd/2jciebu-mqtt-bridge.timer systemd/2jciebu-mqtt-discovery.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now 2jciebu-mqtt-bridge.timer
```

`2jciebu-mqtt-bridge.service`・`2jciebu-mqtt-discovery.service`はどちらも`EnvironmentFile=/opt/2jciebu-mqtt-bridge/.env`で設定を読み込む。`.env`以外のファイルには秘密情報を置かないため、`/etc/systemd/system/`配下のunitファイル自体の権限は既定のままでよい。

Home Assistant向けMQTT Discoveryの登録（初回のみ、冪等なので何度実行してもよい）:

```bash
sudo systemctl start 2jciebu-mqtt-discovery.service
```

## 設定ファイル（`/opt/2jciebu-mqtt-bridge/.env`）

| 変数 | デフォルト | 説明 |
|---|---|---|
| `EXPORTER_URL` | `http://localhost:8000/metrics` | exporterのmetricsエンドポイント。exporter側の`SERVER_HTTP_PORT`と一致させること |
| `MQTT_HOST` | (必須) | MQTTブローカーのホスト |
| `MQTT_PORT` | `1883` | |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | 空 | 空なら認証なしで接続 |
| `MQTT_TOPIC` | `sensors/2jciebu/state` | publish先トピック |
| `DEVICE_ID` | `2jciebu_01` | (Discoveryスクリプト用) Home Assistant上のデバイス識別子。複数センサーを増設する場合はホストごとに一意な値にすること |

ポーリング間隔は`2jciebu-mqtt-bridge.timer`の`OnCalendar=`行（既定`minutely`=1分間隔）で決まる。変更したい場合は`/etc/systemd/system/2jciebu-mqtt-bridge.timer`を編集し`sudo systemctl daemon-reload && sudo systemctl restart 2jciebu-mqtt-bridge.timer`する。

## publishされるJSONの例

```json
{"sensor_omron_temperature":25.3,"sensor_omron_humidity":48.0,"sensor_omron_light":350.5, ...}
```

キー名は`sensor_omron_`で始まる既知の13メトリクスのみ（許可リスト方式）。exporter側にこれ以外のメトリクスが増えても無視され、該当行が1件もマッチしなかった場合はpublishをスキップしてログに警告を残す（無音のデータ欠落を避けるため）。

## 動作確認

```bash
curl -s http://localhost:8000/metrics | grep sensor_omron    # exporterが値を返しているか確認
mosquitto_sub -h <broker> -t sensors/2jciebu/state -v         # 別ターミナルで購読

sudo systemctl start 2jciebu-mqtt-bridge.service               # timerを待たず今すぐ1回実行
journalctl -u 2jciebu-mqtt-bridge.service -n 20                # 実行結果を確認

systemctl list-timers 2jciebu-mqtt-bridge.timer                # 次回実行予定時刻を確認
```

## トラブルシューティング

ログは`journalctl -u 2jciebu-mqtt-bridge.service`（Discoveryは`-u 2jciebu-mqtt-discovery.service`）で確認する。

| ログメッセージ | 原因 | 対処 |
|---|---|---|
| `MQTT_HOST is required` | `/opt/2jciebu-mqtt-bridge/.env`に`MQTT_HOST`が設定されていない、または`.env`自体が存在しない | `.env`を配置し値を設定してから`sudo systemctl start 2jciebu-mqtt-bridge.service`で再実行 |
| `fetch failed: ... unreachable` | exporterが停止中/到達不能 | exporterのサービス状態・`EXPORTER_URL`を確認。次回のtimer実行(最大1分後)で自動的に再試行される |
| `warning: 0 metrics parsed ...` | exporter側のメトリクス形状が変わり、許可リストに一致する行がなくなった | exporterの`/metrics`を確認し、必要なら`poll-and-publish.sh`の許可リストを更新する |
| `mosquitto_pub failed: ... unreachable or auth error` | MQTTブローカーに到達できない、または認証エラー | ブローカーの状態・`MQTT_HOST`/`MQTT_PORT`/認証情報を確認。次回のtimer実行で自動的に再試行される |

timerが動いているか自体を疑う場合は`systemctl status 2jciebu-mqtt-bridge.timer`で`active (waiting)`になっているか、`systemctl list-timers`に`Last`/`Next`の時刻が入っているかを確認する。

## MQTT Discoveryで登録したエンティティを削除したい場合

同じトピックへ空メッセージをretainでpublishすると、Home Assistant側の該当エンティティが削除される:

```bash
mosquitto_pub -h <broker> -r -t "homeassistant/sensor/<device_id>/<metric>/config" -m ""
```

## セキュリティ・制約に関する注意

- MQTTブローカーは信頼できるLAN上にある前提で、TLS対応は行っていない。ブローカーをLAN外に公開する場合は再検討すること。
- センサー本体の故障（`2jciebu-exporter`側の`SensorSerialError`）が起きた場合、exporterは直前の値をHTTP 200で返し続ける。本ブリッジ単体では新鮮な値と古い値を区別できないため、古い値をそのままpublishし続ける可能性がある。

## アンインストール

```bash
sudo systemctl disable --now 2jciebu-mqtt-bridge.timer
sudo rm /etc/systemd/system/2jciebu-mqtt-bridge.service /etc/systemd/system/2jciebu-mqtt-bridge.timer /etc/systemd/system/2jciebu-mqtt-discovery.service
sudo systemctl daemon-reload
sudo rm -rf /opt/2jciebu-mqtt-bridge
```
既存の`2jciebu-exporter`（`2jciebu-prometheus.service`）には一切触れないため、アンインストールしても既存機能への影響はない。
