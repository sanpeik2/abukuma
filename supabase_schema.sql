-- =============================================================================
-- 阿武隈OS — Supabase スキーマ正本
-- プロジェクト: Abukuma-OS (kwhashtnuzrlzrpikhne)
-- 最終更新: 2026-06-02  ← このファイルが唯一の正本
-- 生成元: 本番DBから直接取得 (information_schema + pg_get_viewdef)
-- =============================================================================
-- 注意: このファイルは idempotent (何度実行しても安全)
--   CREATE TABLE IF NOT EXISTS / ADD COLUMN IF NOT EXISTS を使用
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. turbines（風車マスタ）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS turbines (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  turbine_no      text NOT NULL,
  maker           text,
  model_name      text,
  rated_power_kw  numeric,
  hub_height_m    numeric,
  rotor_diameter_m numeric,
  installed_at    date,
  area            text,
  status          text DEFAULT 'active',
  created_at      timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2. inspection_plans（点検計画）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inspection_plans (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id               uuid,
  turbine_id            uuid REFERENCES turbines(id),
  planned_date          date NOT NULL,
  due_date              date,
  status                text DEFAULT 'planned',
  source_type           text DEFAULT 'periodic',
  assigned_to           uuid,
  auto_generated        boolean DEFAULT false,
  notes                 text,
  created_by            uuid,
  created_at            timestamptz DEFAULT now(),
  updated_at            timestamptz DEFAULT now(),
  legacy_id             bigint,
  work_type             text,
  time_start            time,
  time_end              time,
  required_qualification text,
  ptw_number            text,
  worker_count          smallint,
  power_impact_mwh      numeric,
  carryover_from        date,
  revision_no           smallint DEFAULT 1,
  approval_status       text DEFAULT 'draft',
  ptw_required          boolean DEFAULT false,
  ky_required           boolean DEFAULT true,
  loto_required         boolean DEFAULT false,
  plan_no               text,
  inspection_purpose    text,
  inspection_scope      text,
  responsible_person    text,
  checklist_template_id uuid,
  outage_required       boolean DEFAULT false,
  estimated_outage_minutes integer,
  wind_speed_limit_ms   numeric,
  weather_condition     text,
  special_notes         text
);

-- ---------------------------------------------------------------------------
-- 3. inspection_results（点検実績）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inspection_results (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id         uuid REFERENCES inspection_plans(id),
  turbine_id      uuid REFERENCES turbines(id),
  executed_date   date NOT NULL,
  executed_by     uuid,
  start_time      timestamptz,
  end_time        timestamptz,
  weather         text,
  wind_speed_ms   numeric(5,1),
  result_status   text NOT NULL DEFAULT 'ok'
                  CHECK (result_status IN ('ok','ng','conditional')),
  has_anomaly     boolean DEFAULT false,
  anomaly_description text,
  severity        text CHECK (severity IN ('low','medium','high','critical')),
  comments        text,
  submitted_at    timestamptz,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now(),
  approval_status text DEFAULT 'draft',
  revision_no     smallint DEFAULT 1,
  source_type     text,
  source_reason   text,
  ptw_required    boolean DEFAULT false,
  ptw_number      text,
  ky_confirmed    boolean DEFAULT false,
  loto_confirmed  boolean DEFAULT false
);

-- ---------------------------------------------------------------------------
-- 4. defect_findings（異常判断）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS defect_findings (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  turbine_id          uuid REFERENCES turbines(id),
  source_type         text NOT NULL DEFAULT 'inspection',
  source_id           uuid,
  finding_title       text NOT NULL,
  finding_detail      text,
  detected_at         timestamptz NOT NULL DEFAULT now(),
  detected_by         uuid,
  safety_impact       text DEFAULT 'low',
  operation_impact    text DEFAULT 'none',
  cause_clarity       text DEFAULT 'unknown',
  recurrence_type     text DEFAULT 'first',
  regulation_impact   text DEFAULT 'none',
  initial_judgement   text DEFAULT 'tbd',
  status              text DEFAULT 'open',
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now(),
  approval_status     text DEFAULT 'draft',
  revision_no         smallint DEFAULT 1,
  first_check_person  text,
  first_check_at      timestamptz,
  first_check_method  text,
  first_check_notes   text,
  legal_judgement_class text,
  report_required_flag boolean DEFAULT false,
  severity            text
);

-- ---------------------------------------------------------------------------
-- 5. work_orders（作業票）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS work_orders (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_no    text NOT NULL DEFAULT (
    'WO-' || to_char(now(),'YYYYMMDD-') || substring(gen_random_uuid()::text,1,6)
  ),
  turbine_id       uuid REFERENCES turbines(id),
  result_id        uuid,
  source_type      text DEFAULT 'manual',
  source_id        uuid,
  work_type        text,
  anomaly_description text,
  fault_code_id    uuid,
  severity         text DEFAULT 'medium',
  priority         text DEFAULT 'normal',
  assigned_to      uuid,
  planned_date     date,
  status           text DEFAULT 'open',
  response_detail  text,
  root_cause       text,
  temporary_action text,
  permanent_action text,
  downtime_minutes integer,
  estimated_loss_kwh numeric,
  completed_at     timestamptz,
  created_by       uuid,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now(),
  defect_finding_id uuid REFERENCES defect_findings(id),
  approval_status  text DEFAULT 'draft',
  revision_no      smallint DEFAULT 1,
  ky_required      boolean DEFAULT true,
  loto_required    boolean DEFAULT false,
  ky_confirmed     boolean DEFAULT false,
  loto_confirmed   boolean DEFAULT false,
  ptw_required     boolean NOT NULL DEFAULT false,
  planned_start_at timestamptz,
  planned_end_at   timestamptz
);

-- ---------------------------------------------------------------------------
-- 6. work_order_outages（停止・発電影響）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS work_order_outages (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id               uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  turbine_id                  uuid REFERENCES turbines(id),
  outage_occurred             boolean NOT NULL DEFAULT true,
  outage_type                 text,
  started_at                  timestamptz,
  ended_at                    timestamptz,
  downtime_minutes            integer,
  outage_reason               text,
  decided_by                  text,
  decided_role                text,
  decided_at                  timestamptz,
  regulatory_report_candidate boolean NOT NULL DEFAULT false,
  chief_engineer_confirmed    boolean NOT NULL DEFAULT false,
  chief_engineer_confirmed_at timestamptz,
  aggregator_contact_required boolean NOT NULL DEFAULT false,
  lost_energy_kwh             numeric,
  unit_price_jpy              numeric,
  lost_revenue_jpy            numeric,
  note                        text,
  created_by                  uuid,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  chief_engineer_review_status text NOT NULL DEFAULT 'not_required'
);

-- ---------------------------------------------------------------------------
-- 7. work_permits（作業許可 PTW）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS work_permits (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  permit_no        text NOT NULL DEFAULT (
    'PTW-' || to_char(now(),'YYYYMMDD-') || substring(gen_random_uuid()::text,1,6)
  ),
  turbine_id       uuid REFERENCES turbines(id),
  work_order_id    uuid REFERENCES work_orders(id),
  permit_type      text NOT NULL,
  work_description text,
  requested_by     uuid,
  approved_by      uuid,
  permit_status    text DEFAULT 'draft',
  risk_level       text,
  loto_required    boolean DEFAULT false,
  isolations_required boolean DEFAULT false,
  weather_limit_ms numeric,
  start_at         timestamptz,
  end_at           timestamptz,
  approved_at      timestamptz,
  closed_at        timestamptz,
  remarks          text,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 8. ky_records（KY危険予知チェックシート）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ky_records (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  turbine_id       uuid REFERENCES turbines(id),
  work_order_id    uuid REFERENCES work_orders(id),
  permit_id        uuid,
  work_date        date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Tokyo'))::date,
  work_type        text,
  team_leader      uuid,
  weather          text,
  wind_speed_ms    numeric,
  hazard_items     jsonb DEFAULT '[]',
  action_goal      text,
  confirmed_at     timestamptz,
  created_at       timestamptz DEFAULT now(),
  -- 画面入力カラム（追加済み）
  executed_date    date,
  work_description text,
  members          text,
  risk_items       jsonb,
  status           text DEFAULT 'draft',
  updated_at       timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 9. loto_records（LOTO施錠タグアウト）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS loto_records (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id          uuid,
  work_order_id    uuid REFERENCES work_orders(id),
  turbine_id       uuid REFERENCES turbines(id),
  executed_date    date NOT NULL DEFAULT CURRENT_DATE,
  work_description text,
  energy_sources   jsonb DEFAULT '[]',
  status           text DEFAULT 'locked',
  unlock_confirmed_at timestamptz,
  unlock_note      text,
  created_by       uuid,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 10. work_execution_results（作業実施記録）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS work_execution_results (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id         uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  execution_no          smallint NOT NULL DEFAULT 1,
  started_at            timestamptz,
  finished_at           timestamptz,
  executed_by_company   text,
  executed_by_name      text,
  work_summary          text,
  result_status         text NOT NULL DEFAULT 'continued',
  incomplete_reason     text,
  additional_defect_found boolean DEFAULT false,
  next_action           text,
  note                  text,
  created_by            uuid,
  created_at            timestamptz DEFAULT now(),
  updated_at            timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 11. restoration_checks（復旧確認）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS restoration_checks (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id           uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  execution_result_id     uuid REFERENCES work_execution_results(id),
  turbine_id              uuid REFERENCES turbines(id),
  checked_at              timestamptz,
  checked_by_name         text,
  checked_by_role         text,
  trial_run_status        text,
  alarm_status            text,
  scada_status            text,
  generation_restart_status text,
  restoration_status      text NOT NULL DEFAULT 'pending',
  chief_review_status     text DEFAULT 'not_required',
  outage_end_at           timestamptz,
  final_downtime_minutes  integer,
  final_lost_kwh          numeric,
  final_lost_revenue_yen  numeric,
  comment                 text,
  created_by              uuid,
  created_at              timestamptz DEFAULT now(),
  updated_at              timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 12. closeout_reviews（クローズ・最終確認）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS closeout_reviews (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id             uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  review_status             text NOT NULL DEFAULT 'open'
                            CHECK (review_status IN ('open','in_review','returned','closed')),
  report_required           boolean DEFAULT false,
  report_type               text,
  report_deadline           date,
  evidence_status           text DEFAULT 'insufficient'
                            CHECK (evidence_status IN ('insufficient','confirmed')),
  photo_attached            boolean DEFAULT false,
  work_record_attached      boolean DEFAULT false,
  permit_closed             boolean DEFAULT false,
  loto_released             boolean DEFAULT false,
  recurrence_action_required boolean DEFAULT false,
  recurrence_action         text,
  remaining_issue           text,
  closed_by_name            text,
  comment                   text,
  created_by                uuid,
  restoration_check_id      uuid REFERENCES restoration_checks(id),
  defect_finding_id         uuid REFERENCES defect_findings(id),
  closed_at                 timestamptz,
  created_at                timestamptz DEFAULT now(),
  updated_at                timestamptz DEFAULT now(),
  -- 元テーブルの追加カラム（既存互換）
  review_result             text DEFAULT 'pass',
  recovered_at              timestamptz,
  verified_by               uuid,
  lessons_learned           text,
  follow_up_required        boolean DEFAULT false,
  follow_up_detail          text,
  lateral_spread_done       boolean DEFAULT false,
  lateral_spread_note       text
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_closeout_wo ON closeout_reviews(work_order_id);

-- ---------------------------------------------------------------------------
-- 13. approvals（承認履歴）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS approvals (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_type text NOT NULL,
  target_id   uuid NOT NULL,
  action      text NOT NULL,
  reviewed_by uuid NOT NULL,
  comment     text,
  created_at  timestamptz DEFAULT now()
);

-- =============================================================================
-- ビュー定義（本番DBから pg_get_viewdef で取得した正本）
-- =============================================================================

-- v_work_order_outages_summary
CREATE OR REPLACE VIEW v_work_order_outages_summary AS
SELECT work_order_id,
  bool_or(outage_occurred)                                           AS outage_occurred,
  count(*) FILTER (WHERE outage_occurred)                            AS outage_count,
  COALESCE(sum(downtime_minutes) FILTER (WHERE outage_occurred), 0)  AS total_downtime_minutes,
  COALESCE(sum(lost_energy_kwh)  FILTER (WHERE outage_occurred), 0)  AS total_lost_energy_kwh,
  COALESCE(sum(lost_revenue_jpy) FILTER (WHERE outage_occurred), 0)  AS total_lost_revenue_jpy,
  min(started_at)  FILTER (WHERE outage_occurred)                    AS earliest_started_at,
  max(ended_at)    FILTER (WHERE outage_occurred)                    AS latest_ended_at,
  bool_or(regulatory_report_candidate)                               AS regulatory_report_candidate,
  CASE
    WHEN bool_or(chief_engineer_review_status = 'rejected')  THEN 'rejected'
    WHEN bool_or(chief_engineer_review_status = 'pending')   THEN 'pending'
    WHEN bool_or(chief_engineer_review_status = 'confirmed') THEN 'confirmed'
    ELSE 'not_required'
  END                                                                AS chief_engineer_review_status,
  bool_or(aggregator_contact_required)                               AS aggregator_contact_required,
  COALESCE(array_agg(DISTINCT turbine_id) FILTER (WHERE turbine_id IS NOT NULL), '{}') AS turbine_ids
FROM work_order_outages
GROUP BY work_order_id;

-- v_closeout_review_list
CREATE OR REPLACE VIEW v_closeout_review_list AS
SELECT
  c.id, c.work_order_id,
  wo.work_order_no                           AS "作業票番号",
  t.turbine_no                               AS "風車",
  c.review_status,
  CASE c.review_status
    WHEN 'closed'     THEN '✅ クローズ済'
    WHEN 'in_review'  THEN '🔍 確認中'
    WHEN 'returned'   THEN '↩ 差戻し'
    ELSE '📋 未確認'
  END                                        AS "クローズ状態",
  CASE rc.restoration_status
    WHEN 'restored'      THEN '✅ 復旧済'
    WHEN 'rework'        THEN '🔁 再作業'
    WHEN 'not_restored'  THEN '🔴 復旧不可'
    WHEN 'pending'       THEN '⏳ 確認中'
    ELSE '—'
  END                                        AS "復旧状態",
  c.report_required                          AS "報告要否",
  c.report_type                              AS "報告種別",
  c.report_deadline                          AS "報告期限",
  CASE c.evidence_status WHEN 'confirmed' THEN '✅ 確認済' ELSE '⚠ 不足' END AS "証跡",
  c.permit_closed                            AS "PTW終了",
  c.loto_released                            AS "LOTO解除",
  c.recurrence_action_required               AS "再発防止要",
  c.remaining_issue                          AS "残課題",
  COALESCE(NULLIF(c.closed_by_name,''),'—') AS "確認者",
  (c.closed_at AT TIME ZONE 'Asia/Tokyo')   AS "クローズ日時",
  array_to_string(array_remove(ARRAY[
    CASE WHEN c.report_required THEN '⚖ 報告要' END,
    CASE WHEN c.report_required AND c.report_deadline IS NOT NULL
              AND c.report_deadline < CURRENT_DATE
              AND c.review_status <> 'closed' THEN '🟥 報告期限超過' END,
    CASE WHEN c.evidence_status = 'insufficient' THEN '⚠ 証跡不足' END,
    CASE WHEN c.permit_closed  = false           THEN '🔒 PTW未終了' END,
    CASE WHEN c.loto_released  = false           THEN '🔒 LOTO未解除' END,
    CASE WHEN c.recurrence_action_required       THEN '🔁 再発防止要' END,
    CASE WHEN NULLIF(c.remaining_issue,'') IS NOT NULL THEN '📌 残課題あり' END
  ], NULL), ' / ')                           AS "重要事項",
  c.defect_finding_id, c.restoration_check_id, c.created_at
FROM closeout_reviews c
JOIN  work_orders wo  ON wo.id  = c.work_order_id
LEFT JOIN turbines t  ON t.id   = wo.turbine_id
LEFT JOIN restoration_checks rc ON rc.id = c.restoration_check_id
ORDER BY c.created_at DESC;

-- v_restoration_check_list
CREATE OR REPLACE VIEW v_restoration_check_list AS
SELECT
  r.id, r.work_order_id,
  wo.work_order_no                           AS "作業票番号",
  t.turbine_no                               AS "風車",
  r.restoration_status,
  CASE r.restoration_status
    WHEN 'restored'     THEN '✅ 復旧済'
    WHEN 'rework'       THEN '🔁 再作業'
    WHEN 'not_restored' THEN '🔴 復旧不可'
    ELSE '⏳ 確認中'
  END                                        AS "復旧状態",
  CASE r.trial_run_status
    WHEN 'good'    THEN '✅ 良好' WHEN 'recheck' THEN '🟡 要再確認'
    WHEN 'ng'      THEN '🔴 NG'  ELSE '—'
  END                                        AS "試運転",
  CASE r.alarm_status
    WHEN 'cleared'   THEN '✅ 解消' WHEN 'remaining' THEN '🔴 残あり' ELSE '—'
  END                                        AS "アラーム",
  CASE r.scada_status
    WHEN 'normal'   THEN '✅ 正常' WHEN 'abnormal' THEN '🔴 異常'
    WHEN 'unchecked' THEN '— 未確認' ELSE '—'
  END                                        AS "SCADA",
  CASE r.generation_restart_status
    WHEN 'ok' THEN '✅ 可' WHEN 'no' THEN '🔴 不可'
    WHEN 'conditional' THEN '🟡 条件付き' ELSE '—'
  END                                        AS "発電再開",
  CASE r.chief_review_status
    WHEN 'confirmed' THEN '✅ 済' WHEN 'pending' THEN '🟡 待ち'
    WHEN 'rejected'  THEN '🔴 差戻し' ELSE '—'
  END                                        AS "主任確認",
  COALESCE(NULLIF(r.checked_by_name,''),'—') AS "確認者",
  (r.checked_at AT TIME ZONE 'Asia/Tokyo')  AS "確認日時",
  r.final_downtime_minutes                   AS "確定停止min",
  r.final_lost_kwh                           AS "確定逸失kwh",
  r.final_lost_revenue_yen                   AS "確定逸失円",
  array_to_string(array_remove(ARRAY[
    CASE WHEN r.restoration_status = 'rework'        THEN '🔁 再作業' END,
    CASE WHEN r.restoration_status = 'not_restored'  THEN '🔴 復旧不可' END,
    CASE WHEN r.trial_run_status   = 'ng'            THEN '⚠ 試運転NG' END,
    CASE WHEN r.alarm_status       = 'remaining'     THEN '⚠ アラーム残' END,
    CASE WHEN r.generation_restart_status = 'no'     THEN '⛔ 発電不可' END,
    CASE WHEN r.chief_review_status = 'pending'      THEN '🟡 主任待ち' END
  ], NULL), ' / ')                           AS "重要事項",
  r.execution_result_id, r.created_at
FROM restoration_checks r
JOIN  work_orders wo ON wo.id = r.work_order_id
LEFT JOIN turbines t ON t.id  = wo.turbine_id
ORDER BY r.created_at DESC;

-- =============================================================================
-- RLS ポリシー（authenticated ユーザーは全操作可。anon はブロック）
-- 2026-06-02 適用済み
-- =============================================================================
-- 対象テーブル:
--   work_orders, defect_findings, work_order_outages, closeout_reviews,
--   restoration_checks, work_execution_results, ky_records, loto_records,
--   approvals, inspection_plans, inspection_results, work_permits
--
-- ポリシー名: rls_auth_all
-- 内容: FOR ALL TO authenticated USING (true) WITH CHECK (true)
--
-- 将来の拡張案:
--   主任技術者 (chief_engineer ロール) のみ chief_review_status を更新可能に制限
--   → CREATE POLICY rls_chief_only ON restoration_checks
--       FOR UPDATE TO authenticated
--       USING (true)
--       WITH CHECK (
--         chief_review_status = OLD.chief_review_status  -- 変更なしは誰でもOK
--         OR EXISTS (
--           SELECT 1 FROM user_roles
--           WHERE user_id = auth.uid() AND role = 'chief_engineer'
--         )
--       );
-- =============================================================================
