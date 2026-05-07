# yakiimo-temp-monitor — Claude Code session-load instructions

ESP32 + Cloudflare Workers + Supabase でやきいも下焼き工程の温度を計測・公開するプロジェクト。

## このプロジェクトでリファクタリング / 修正作業を始める前に必読

deploy 環境 (Workers 構成、build pipeline、172478a 事故記録、運用ルール) は `docs/DEPLOY.md` に集約してある。これは @-import で本文書から自動展開される。

@docs/DEPLOY.md

## 重要な原則

1. **deploy topology を「コードコメントや過去文書」だけで判断しない**。`docs/DEPLOY.md` と CF dashboard の現状を一次出典として確認すること。コメント rot を信用すると 172478a のような事故が再発する
2. **アーキテクチャ系の deepening / リファクタリングをする時は、計画策定後に `architecture-proposal-review` skill で Gemini 独立 review を必ず通す**。Stage 0 (Claude 判断) を Stage 1 (Gemini) に渡さない設計を踏襲する
3. **CF Workers Build 設定の変更履歴は CF dashboard でしか分からない**。本リポにはその履歴は残らないので、変更したら必ず `docs/DEPLOY.md` の該当節を更新すること

## 関連文書 (必要時に手動で読む)

- ドメイン辞書: `docs/CONTEXT.md`
- 設計判断記録: `docs/adr/`
- Ingest Contract 仕様: `docs/CONTRACT.md`
