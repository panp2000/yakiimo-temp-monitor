# ADR-0001: Plausibility validation の deferral

## Status

Accepted (2026-05-07)

## Context

Yakiimo Ingest Contract の Payload Schema は **constraint level** (技術的に成立するレンジ) のみを定義し、**plausibility level** (yakiimo として normal な値の窓) は意図的に含めない設計である。

例:
- constraint: `temp_c` は -50〜1500°C (物理的に成立する範囲)
- plausibility (除外): `temp_c` は 0〜800°C (typical な焼き芋セッション)

これにより「契約は通るが yakiimo として ありえない」値が Worker / DB を通過する可能性がある。

## Decision

Plausibility の constants は本契約に含めず、将来の独立 deepening として残す。

## Rationale

Yakiimo の物理運用条件が未確定:

- 現状: 自宅釜での運用、外気温は数℃〜30℃程度
- 将来 1: 冬の最低気温が -14°C になる地域での運用
- 将来 2: 真冬の北海道での運用なら -50°C までバッファが必要かもしれない
- 焼き釜の上限温度も実機・薪量・運用次第

これらが固まらぬ段階で plausibility を pre-commit すると:

1. 運用拡張時に毎回契約を破る (constraint と異なり plausibility は context-sensitive)
2. False positive が増え、Worker / DB が legitimate データを誤拒否
3. 契約の更新が頻繁になり、3 言語の同期 cost が嵩む

constraint level (技術的に通せる範囲) のみを本契約で固定し、plausibility は将来 admin layer での post-hoc 検出 (ダッシュボード上の anomaly flag、統計的アラート等) として分離する方針。

## Consequences

- Yakiimo Ingest Contract は data integrity (技術的) のみ保証、運用妥当性は別層
- 攻撃者が「constraint 内、plausibility 外」のデータを送り込む可能性は残るが、本 deepening の対象外
- L4 (plausibility) を将来導入する際、本契約への追加 / 別 module どちらでも可能 (contract が拡張可能形ゆえ)
- 物理運用条件が固まった時点で本 ADR を superseded として update し、新規 ADR で plausibility 導入を記録する
