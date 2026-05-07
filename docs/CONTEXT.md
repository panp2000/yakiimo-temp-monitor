# yakiimo-temp-monitor — Domain Glossary

このプロジェクトのドメイン用語と概念を定義します。アーキテクチャ用語 (Module / Interface / Seam 等) は別途扱います。

## Session

ESP32 から DB に流入する温度時系列の論理単位。`session_id` (TEXT、形式: `^[a-zA-Z0-9_-]{1,64}$`) で識別します。1 セッションは「1 回の焼き芋セッション」「冷却試験」「キャリブレーション」など、用途を問わず時系列をまとめる単位です。

- ESP32 Web UI で `session_id_var` を変更すると新セッション開始
- DB の `yakiimo_sessions` テーブルに first INSERT 時に自動登録 (BEFORE INSERT trigger)
- `is_public=true` は同時に 1 セッションのみ (排他、partial unique index + trigger)
- `pg_cron` が 5 分毎に走り、`ended_at` が 30 分以上前のセッションを自動的に `is_public=false` に戻す

## Channel

1 セッション内で並走する観測対象。5 種類:

| Channel | 内容 | センサ |
|---------|------|--------|
| `potato_internal` | 焼き芋内部温度 | K 型熱電対 (MAX31855) |
| `potato_surface`  | 焼き芋表面温度 | K 型熱電対 (MAX31855) |
| `kiln_ambient`    | 釜内雰囲気温度 | K 型熱電対 (MAX31855) |
| `stone_surface`   | 焼き石表面温度 | K 型熱電対 (MAX31855) |
| `env`             | 環境気温 / 湿度 / 気圧 | BME280 |

`env` チャンネルのみ humidity_pct / pressure_hpa を持ちます。他は temp_c のみ。

## Yakiimo Ingest Contract

ESP32 → Cloudflare Worker → Supabase の経路で交わされる契約。3 言語 (C++ / TypeScript / SQL) にまたがる単一 source of truth として `contract/` module で集約管理します。Envelope (認証層) + Payload Schema (データ層) + Contract Version で構成されます。

- TypeScript で source を書き、codegen で C++ ヘッダと SQL 関数を生成
- 公開ドキュメント `docs/CONTRACT.md` は同じ source から自動生成

## Envelope

HMAC 認証層の契約。ESP32 が Worker に送る POST リクエストの認証情報を定義します。

- Message format: `${version}\n${timestamp}\n${body}` を HMAC-SHA256 で署名
- ヘッダ: `X-Yakiimo-Timestamp` (Unix epoch 秒) / `X-Yakiimo-Signature` (hex 64 chars)
- Timestamp tolerance: 過去 300 秒 / 未来 60 秒
- 共有秘密は ESP32 secrets.yaml と Cloudflare Worker secret に同値で保管

## Payload Schema

`yakiimo_temp_logs` に挿入される 1 行 (LogRow) の制約。

- 必須: device_id (regex), session_id (regex), measured_at (ISO 8601 UTC), channel (5 値), temp_c (range)
- 任意 (env channel のみ): humidity_pct, pressure_hpa
- 値域は **constraint level** (技術的に成立する範囲、例: temp_c -50〜1500°C)
- **Plausibility level** (yakiimo として normal な値の窓) は本契約に含まれません (ADR-0001 参照)

## Contract Version

Envelope と Payload Schema を一括して識別する整数。format 変更時に increment します。Worker は known version のみ accept (forward compatibility)。version 1 が現行です。

---

## 関連ドキュメント

- `docs/CONTRACT.md` — Yakiimo Ingest Contract の完全仕様 (codegen 自動生成)
- `docs/adr/` — Architecture Decision Records
- `README.md` — プロジェクト概要とセットアップ手順
- `contract/src/` — Contract module の TypeScript 実装
- [Deploy environment](DEPLOY.md) — Workers 構成・build pipeline・運用ルール
