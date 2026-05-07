# ADR-0002: 2038 年問題の根治を defer

## Status

Accepted (2026-05-07)

## Context

ESP32 firmware (Arduino-ESP32 / ESP-IDF) の `time_t` は **signed 32-bit**。
2038-01-19 03:14:08 UTC に signed overflow を起こし、負値にラップする。

Yakiimo Ingest Contract では:

1. ESP32 lambda で `id(sntp_time).now().timestamp` (`time_t` 型) を取得
2. これを cast して文字列化、`X-Yakiimo-Timestamp` header と HMAC message に埋込
3. Worker は header から timestamp を読み、HMAC で再計算した message と比較

Stage 10-A 修正前は cast 幅が異なり (`unsigned long` 32-bit と `unsigned long long` 64-bit が混在)、2038 年以降に header と HMAC message で異なる timestamp 表現が出る欠陥があった。Stage 10-A/10-B で全ての cast を `unsigned long long` (64-bit) に統一し、内部一貫性は確保した。

但しこれは「2038 年に header と HMAC が一致した形でラップする」だけで、根治ではない。ラップ後の巨大 unsigned 値は Worker の `TIMESTAMP_TOLERANCE_FUTURE_SEC` (60 秒) を遥かに超え、`timestamp_out_of_range` で全 ingest が reject される。

## Decision

2038 年問題の根治は本契約の現在の version では実装せず、defer する。

具体的には:

- ESP-IDF / Arduino-ESP32 framework が 64-bit `time_t` (`time64_t` 等) を提供した時点で再対応
- それまでは Stage 10-A/10-B の cast 統一による内部一貫性のみ維持
- 2038 年が近づいた段階で本 ADR を superseded として update し、framework 移行 ADR を新規作成

## Rationale

1. **根治不可**: source の `t.timestamp` が 32-bit signed である限り、cast の表現幅をいくら広げても overflow 自体は防げない。framework 側の `time_t` 拡張が必須。
2. **時間的猶予**: 2038-01-19 まで約 12 年あり、その間に framework 側の対応が進む可能性高い (Linux カーネル / glibc は既に `__time64_t` 等で 64-bit 化対応中)。
3. **failure mode が観測可能**: 2038 年に問題が顕在化する場合、Worker log で `timestamp_out_of_range` の連発として明確に検出できる。silent corruption ではない。
4. **代替案のコスト過大**: ESP32 上で独自 64-bit 時刻管理を実装する案もあるが、SNTP 同期 / ESPTime API / 既存 lambda 構造との整合を破る変更で、得られる便益 (12 年後への備え) に見合わない。

## Consequences

- 2038-01-19 以降、ESP32 → Worker → Supabase 経路は **`timestamp_out_of_range` で停止**
- 復旧には framework 側の 64-bit `time_t` 採用 + ESP32 firmware 再書込みが必要
- 復旧時には本 ADR を superseded、新 ADR で framework 移行を記録
- 2038 年以前の運用には影響なし

## 関連

- 内部一貫性確保: Stage 10-A (`contract/codegen/emit-c-header.ts` で `unsigned long long`)、Stage 10-B (`firmware-esphome/yakiimo.yaml` の cast 統一)
- contract module の version negotiation (`contract/src/envelope.ts` の `SUPPORTED_VERSIONS`) は本問題と独立 — 但し将来 framework 移行時に format 変更があれば SUPPORTED_VERSIONS に新 version 追加で smooth migration 可能
