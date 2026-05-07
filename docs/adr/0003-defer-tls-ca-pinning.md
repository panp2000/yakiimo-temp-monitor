# ADR-0003: ESP32 → Worker の TLS CA 固定を defer

## Status

Accepted (2026-05-07)

## Context

`docs/THREAT-MODEL.md` の "Honest gaps" 第 3 項に記載の通り、`firmware-esphome/yakiimo.yaml:113` で `verify_ssl: false` を設定しており、ESP32 → Cloudflare Worker (`https://yakiimo-ingest.<account>.workers.dev`) 間の TLS は endpoint validation を行っていない。完全な TLS MITM 攻撃下では攻撃者が CA 偽装で session key を握れるため、body は平文相当で観測される。HMAC envelope (`contract/src/envelope.ts`) が integrity を担保するため payload 改竄は防げるが、confidentiality は session key 侵害リスクが残る。

Phase 14-B にて以下の調査を行った:

1. ESPHome 公式ドキュメント (https://esphome.io/components/http_request/) では `ca_certificate_path` (PEM-encoded CA file path) と `verify_ssl: true` の組合せで CA 固定が可能とされている。但しこれは **ESP32 + ESP-IDF framework 前提**。
2. ESPHome 公式ドキュメントは Arduino framework について「`verify_ssl` must be explicitly set to `false` on other platforms」と記載しており、Arduino では `true` を設定できない。
3. ESPHome のソースコード `http_request_arduino.cpp` (https://api-docs.esphome.io/http__request__arduino_8cpp_source) を直接確認した結果、Arduino 実装は HTTPS 接続時に **無条件で `WiFiClientSecure::setInsecure()` を呼び出している**。`setCACert()` も `ca_certificate_path` 処理も存在しない。すなわち Arduino framework では yaml レベルでも C++ レベルでも CA pinning は実現不可能。

本リポは `firmware-esphome/yakiimo.yaml:48` で `framework: type: arduino` を採用している。CA 固定を実現するには ESP-IDF framework への切替えが必要となり、これは以下を含む大規模リファクタリングである:

- `esp32.framework.type: esp-idf` への切替
- ESP-IDF 固有の build option (`sdkconfig` 等) の調整
- `hmac_helper.h` (mbedtls 依存) の ESP-IDF mbedtls API への適合確認
- `max31855` / `bme280_i2c` / `web_server` 等の component が ESP-IDF で同等動作することの検証
- OTA / captive_portal / wifi の framework 切替時の挙動確認

## Decision

ESP32 → Worker の TLS CA 固定は当面 **defer する**。`firmware-esphome/yakiimo.yaml:113` は `verify_ssl: false` を維持する。

## Rationale

1. **現状の脅威モデルでリスク許容範囲内**:
   - HMAC envelope (Worker `/ingest` 側で `signature_mismatch` / `timestamp_out_of_range` を検証) が integrity を担保しているため、MITM 下でも payload 改竄や偽装 ingest は防げる。
   - 公開リポ + 焼き芋屋 portfolio という運用文脈で、攻撃者が ESP32 → Worker 経路に CA 偽装 MITM を仕掛けるインセンティブは低い。
   - 露出する body は温度・湿度・気圧・session_id・device_id・measured_at のみで、商業秘密に直結するのは焼成プロファイル温度カーブのみ (これは別途 `THREAT-MODEL.md` gap 6 "business intelligence 推測" で公開 dashboard 経由の漏洩としても扱われている)。
2. **修正コストが脅威モデルに見合わない**:
   - Arduino → ESP-IDF framework 切替は本リポの ESPHome component 全体に波及する大規模変更で、検証コストが高い。
   - yaml 単体修正や custom C++ component 追加では根本解決できない (Arduino 実装が `setInsecure()` を hard-code している)。
3. **検出可能な fail mode**:
   - 攻撃者が CA 偽装 MITM で session key を握り、body を平文観測しても、HMAC を改竄すれば Worker 側 `signature_mismatch` で reject される (`worker/src/index.ts:55`)。攻撃の成立には HMAC secret も同時侵害が必要で、その場合は本 ADR の対象範囲外 (gap 1, A2 / A4) になる。

## Trigger to revisit

以下のいずれかが成立した時点で本 ADR を superseded とし、CA 固定を再評価する:

1. ESPHome の Arduino framework 実装で yaml-level CA pinning がサポートされた時 (`http_request_arduino.cpp` の `setInsecure()` hard-code が解消され、`verify_ssl: true` / `ca_certificate_path` が Arduino でも動作するようになった時)。
2. 本 firmware で機密性を要求する body 変更があった時 (個人情報、店舗内部情報、決済関連データ等の追加)。
3. 別件で ESP-IDF framework への切替リファクタが行われた時 (CA 固定を併せて実装する)。
4. CA 偽装 MITM 攻撃の実例が観測された、もしくは本リポ運用文脈で攻撃インセンティブが上昇した時。

## Consequences

- ESP32 → Worker 経路で TLS encryption は機能するが endpoint validation は行わない。CA 偽装 MITM 攻撃下では body 平文を観測される。
- HMAC envelope による integrity は維持され、payload 改竄や偽装 ingest は引き続き防げる。
- 商業秘密性のある温度プロファイルが MITM 経路観測者・上流 ISP 等に晒されるリスクは残存。但し公開 dashboard (anon 経路) 経由でも温度プロファイルは閲覧可能 (`is_public=true` 中) のため、追加リスクは「公開 OFF 中も観測可能」「過去 logs 観測可能」の点に限定される。
- `docs/THREAT-MODEL.md` gap 3 を本 ADR への参照付きで「defer 判断済」へ更新する。

## 関連

- THREAT-MODEL gap 3: `docs/THREAT-MODEL.md` の "Honest gaps" 第 3 項
- ESPHome Arduino 実装: https://api-docs.esphome.io/http__request__arduino_8cpp_source (無条件 `setInsecure()`)
- ESPHome 公式 docs: https://esphome.io/components/http_request/
- HMAC envelope: `contract/src/envelope.ts`、`worker/src/index.ts:46-54`
