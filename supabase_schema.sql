-- =====================================================================
--  阿武隈OS — 追加スキーマ（本セッションで作成したDDL）
--  Supabase / PostgreSQL
--  ※ 既存スキーマへの追加分。冪等になるよう IF NOT EXISTS / OR REPLACE を使用。
-- =====================================================================


-- ---------------------------------------------------------------------
-- 点検計画 × チェックリスト（多対多 junction）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inspection_plan_checklists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inspection_plan_id uuid NOT NULL REFERENCES inspection_plans(id) ON DELETE CASCADE,
  template_id uuid NOT NULL REFERENCES inspection_checklist_templates(id),
  sort_order integer DEFAULT 1,
  note text,
  created_at timestamptz DEFAULT now(),
  UNIQUE (inspection_plan_id, template_id)
);
CREATE INDEX IF NOT EXISTS idx_ipc_plan ON inspection_plan_checklists(inspection_plan_id);
CREATE INDEX IF NOT EXISTS idx_ipc_template ON inspection_plan_checklists(template_id);


-- ---------------------------------------------------------------------
-- 安全確認ルール（KY必須／PTW・LOTO条件付き）
-- ---------------------------------------------------------------------
ALTER TABLE work_orders ADD COLUMN IF NOT EXISTS ptw_required boolean NOT NULL DEFAULT false;
ALTER TABLE work_orders ADD COLUMN IF NOT EXISTS planned_start_at timestamptz;
ALTER TABLE work_orders ADD COLUMN IF NOT EXISTS planned_end_at   timestamptz;
ALTER TABLE inspection_plans ALTER COLUMN ky_required SET DEFAULT true;
ALTER TABLE work_orders      ALTER COLUMN ky_required SET DEFAULT true;


-- ---------------------------------------------------------------------
-- 承認(approvals) target_type 許可値の拡張
-- ---------------------------------------------------------------------
ALTER TABLE approvals DROP CONSTRAINT IF EXISTS approvals_target_type_check;
ALTER TABLE approvals ADD CONSTRAINT approvals_target_type_check
  CHECK (target_type = ANY (ARRAY[
    'inspection_result','inspection_plan','work_order','work_permit',
    'permit','defect_finding','near_miss','moc_change'
  ]::text[]));


-- ---------------------------------------------------------------------
-- 承認済みロックの緩和（content編集はロック、進行系カラムは許可）
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_lock_inspection_plan() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_check inspection_plans;
BEGIN
  IF OLD.approval_status = 'approved'
     AND (NEW.approval_status IS NOT DISTINCT FROM OLD.approval_status) THEN
    v_check := NEW;
    v_check.status     := OLD.status;
    v_check.ptw_number := OLD.ptw_number;
    v_check.updated_at := OLD.updated_at;
    IF ROW(v_check.*) IS DISTINCT FROM ROW(OLD.*) THEN
      RAISE EXCEPTION 'record_locked: 点検計画は承認済みのため編集できません。差戻しが必要です。(id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_lock_work_order() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v work_orders;
BEGIN
  IF OLD.approval_status = 'approved'
     AND (NEW.approval_status IS NOT DISTINCT FROM OLD.approval_status) THEN
    v := NEW;
    v.status         := OLD.status;
    v.completed_at   := OLD.completed_at;
    v.updated_at     := OLD.updated_at;
    v.ky_confirmed   := OLD.ky_confirmed;
    v.loto_confirmed := OLD.loto_confirmed;
    v.planned_start_at := OLD.planned_start_at;
    v.planned_end_at   := OLD.planned_end_at;
    IF ROW(v.*) IS DISTINCT FROM ROW(OLD.*) THEN
      RAISE EXCEPTION 'record_locked: この作業票は承認済みのため編集できません。差戻しが必要です。(id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_lock_work_orders ON work_orders;
CREATE TRIGGER trg_lock_work_orders BEFORE UPDATE ON work_orders
  FOR EACH ROW EXECUTE FUNCTION fn_lock_work_order();


-- ---------------------------------------------------------------------
-- 点検計画ステータスを点検結果の有無で自動同期
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_plan_status_from_results() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
    IF NEW.plan_id IS NOT NULL THEN
      UPDATE inspection_plans SET status = 'completed'
       WHERE id = NEW.plan_id AND status NOT IN ('on_hold','cancelled','completed');
    END IF;
    RETURN NEW;
  ELSIF (TG_OP = 'DELETE') THEN
    IF OLD.plan_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM inspection_results WHERE plan_id = OLD.plan_id) THEN
      UPDATE inspection_plans SET status = 'planned'
       WHERE id = OLD.plan_id AND status = 'completed';
    END IF;
    RETURN OLD;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_sync_plan_status_ins ON inspection_results;
CREATE TRIGGER trg_sync_plan_status_ins
  AFTER INSERT OR UPDATE OF plan_id ON inspection_results
  FOR EACH ROW EXECUTE FUNCTION sync_plan_status_from_results();
DROP TRIGGER IF EXISTS trg_sync_plan_status_del ON inspection_results;
CREATE TRIGGER trg_sync_plan_status_del
  AFTER DELETE ON inspection_results
  FOR EACH ROW EXECUTE FUNCTION sync_plan_status_from_results();


-- ---------------------------------------------------------------------
-- 作業票の作業時間帯 → PTW(draft/submitted)へ自動反映
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_ptw_times_from_wo() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.planned_start_at IS DISTINCT FROM OLD.planned_start_at
      OR NEW.planned_end_at IS DISTINCT FROM OLD.planned_end_at) THEN
    UPDATE work_permits
       SET start_at   = COALESCE(NEW.planned_start_at, start_at),
           end_at     = COALESCE(NEW.planned_end_at,   end_at),
           updated_at = now()
     WHERE work_order_id = NEW.id
       AND permit_status IN ('draft','submitted');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_sync_ptw_times ON work_orders;
CREATE TRIGGER trg_sync_ptw_times
  AFTER UPDATE OF planned_start_at, planned_end_at ON work_orders
  FOR EACH ROW EXECUTE FUNCTION sync_ptw_times_from_wo();


-- ---------------------------------------------------------------------
-- RCA（根本原因調査）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rca_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rca_no text UNIQUE,
  defect_finding_id uuid NOT NULL REFERENCES defect_findings(id) ON DELETE CASCADE,
  work_order_id uuid REFERENCES work_orders(id),
  turbine_id uuid REFERENCES turbines(id),
  method text NOT NULL DEFAULT '5why' CHECK (method IN ('5why','fishbone','fault_tree','other')),
  why1 text, why2 text, why3 text, why4 text, why5 text,
  contributing_factors text, root_cause text, permanent_action text,
  owner text, due_date date,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','done','cancelled')),
  approval_status text NOT NULL DEFAULT 'draft' CHECK (approval_status IN ('draft','pending','approved','returned')),
  note text, created_by uuid,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rca_defect ON rca_reports(defect_finding_id);
CREATE INDEX IF NOT EXISTS idx_rca_wo ON rca_reports(work_order_id);


-- ---------------------------------------------------------------------
-- Step 9. 作業実施
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS work_execution_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  execution_no smallint NOT NULL DEFAULT 1,
  started_at timestamptz, finished_at timestamptz,
  executed_by_company text, executed_by_name text,
  work_summary text,
  result_status text NOT NULL DEFAULT 'continued'
    CHECK (result_status IN ('completed','partial','cancelled','continued')),
  incomplete_reason text,
  additional_defect_found boolean DEFAULT false,
  next_action text, note text, created_by uuid,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_wer_wo ON work_execution_results(work_order_id);


-- ---------------------------------------------------------------------
-- Step 10. 復旧確認
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS restoration_checks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  execution_result_id uuid REFERENCES work_execution_results(id),
  turbine_id uuid REFERENCES turbines(id),
  checked_at timestamptz, checked_by_name text, checked_by_role text,
  trial_run_status text CHECK (trial_run_status IN ('good','recheck','ng')),
  alarm_status text CHECK (alarm_status IN ('cleared','remaining')),
  scada_status text CHECK (scada_status IN ('normal','abnormal','unchecked')),
  generation_restart_status text CHECK (generation_restart_status IN ('ok','no','conditional')),
  restoration_status text NOT NULL DEFAULT 'pending'
    CHECK (restoration_status IN ('pending','restored','not_restored','rework')),
  chief_review_status text DEFAULT 'not_required'
    CHECK (chief_review_status IN ('not_required','pending','confirmed','rejected')),
  outage_end_at timestamptz,
  final_downtime_minutes integer, final_lost_kwh numeric, final_lost_revenue_yen numeric,
  comment text, created_by uuid,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rc_wo ON restoration_checks(work_order_id);


-- ---------------------------------------------------------------------
-- 状態自動連動：作業実施 / クローズ → 作業票ステータス
--   （安全ゲート尊重：LOTO解除前は自動completeしない）
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_wo_status_from_execution() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_loto_req boolean; v_loto_ok boolean;
BEGIN
  UPDATE work_orders SET status='in_progress'
   WHERE id = NEW.work_order_id AND status = 'open';
  IF NEW.result_status = 'completed' THEN
    SELECT COALESCE(loto_required,false) INTO v_loto_req FROM work_orders WHERE id = NEW.work_order_id;
    v_loto_ok := (NOT v_loto_req)
                 OR EXISTS (SELECT 1 FROM loto_records WHERE work_order_id = NEW.work_order_id AND status = 'unlocked');
    IF v_loto_ok THEN
      UPDATE work_orders SET status='completed', completed_at = COALESCE(completed_at, now())
       WHERE id = NEW.work_order_id AND status <> 'cancelled';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_sync_wo_from_exec ON work_execution_results;
CREATE TRIGGER trg_sync_wo_from_exec
  AFTER INSERT OR UPDATE OF result_status, work_order_id ON work_execution_results
  FOR EACH ROW EXECUTE FUNCTION sync_wo_status_from_execution();

CREATE OR REPLACE FUNCTION sync_wo_status_from_closeout() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.review_status = 'closed' THEN
    IF NEW.closed_at IS NULL THEN NEW.closed_at := now(); END IF;
    UPDATE work_orders SET status='completed', completed_at = COALESCE(completed_at, now())
     WHERE id = NEW.work_order_id AND status <> 'cancelled';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_sync_wo_from_closeout ON closeout_reviews;
CREATE TRIGGER trg_sync_wo_from_closeout
  BEFORE INSERT OR UPDATE OF review_status ON closeout_reviews
  FOR EACH ROW EXECUTE FUNCTION sync_wo_status_from_closeout();


-- ---------------------------------------------------------------------
-- Step 11. クローズ・報告確認
--   ※ まっさらな環境でも再現できるよう CREATE TABLE IF NOT EXISTS を先に実行。
--      既存DB（旧スキーマの closeout_reviews）には後続 ALTER で不足カラムを追加。
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS closeout_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  closed_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE closeout_reviews
  ADD COLUMN IF NOT EXISTS restoration_check_id uuid REFERENCES restoration_checks(id),
  ADD COLUMN IF NOT EXISTS defect_finding_id uuid REFERENCES defect_findings(id),
  ADD COLUMN IF NOT EXISTS review_status text NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS report_required boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS report_type text,
  ADD COLUMN IF NOT EXISTS report_deadline date,
  ADD COLUMN IF NOT EXISTS evidence_status text DEFAULT 'insufficient',
  ADD COLUMN IF NOT EXISTS photo_attached boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS work_record_attached boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS permit_closed boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS loto_released boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS recurrence_action_required boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS recurrence_action text,
  ADD COLUMN IF NOT EXISTS remaining_issue text,
  ADD COLUMN IF NOT EXISTS closed_by_name text,
  ADD COLUMN IF NOT EXISTS comment text,
  ADD COLUMN IF NOT EXISTS created_by uuid;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='closeout_reviews_review_status_check') THEN
    ALTER TABLE closeout_reviews ADD CONSTRAINT closeout_reviews_review_status_check
      CHECK (review_status IN ('open','in_review','returned','closed'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='closeout_reviews_evidence_status_check') THEN
    ALTER TABLE closeout_reviews ADD CONSTRAINT closeout_reviews_evidence_status_check
      CHECK (evidence_status IN ('insufficient','confirmed'));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_closeout_wo ON closeout_reviews(work_order_id);


-- =====================================================================
--  Step 9-11 一覧ビュー（実体定義）
--  画面（work-execution.html / restoration.html / closeout.html）が直接読む。
-- =====================================================================

DROP VIEW IF EXISTS v_work_execution_list;
CREATE VIEW v_work_execution_list AS
SELECT e.id, e.work_order_id,
  wo.work_order_no AS "作業票番号", t.turbine_no AS "風車", e.execution_no AS "実施回",
  e.result_status,
  CASE e.result_status WHEN 'completed' THEN '✅ 完了' WHEN 'partial' THEN '🟡 一部完了'
    WHEN 'cancelled' THEN '✖ 中止' ELSE '🔧 継続' END AS "作業状態",
  COALESCE(NULLIF(e.executed_by_name,''),'—') AS "実施担当",
  e.executed_by_company AS "実施会社",
  (e.started_at  AT TIME ZONE 'Asia/Tokyo') AS "開始日時",
  (e.finished_at AT TIME ZONE 'Asia/Tokyo') AS "完了日時",
  e.work_summary AS "実施内容", e.incomplete_reason AS "未完了理由",
  e.additional_defect_found AS "追加不具合", e.next_action AS "次アクション",
  (SELECT count(*) FROM attachments a WHERE a.target_type='work_execution_result' AND a.target_id=e.id) AS "添付数",
  e.created_at
FROM work_execution_results e
JOIN work_orders wo ON wo.id=e.work_order_id
LEFT JOIN turbines t ON t.id=wo.turbine_id
ORDER BY e.created_at DESC;

DROP VIEW IF EXISTS v_restoration_check_list;
CREATE VIEW v_restoration_check_list AS
SELECT r.id, r.work_order_id,
  wo.work_order_no AS "作業票番号", t.turbine_no AS "風車", r.restoration_status,
  CASE r.restoration_status WHEN 'restored' THEN '✅ 復旧済' WHEN 'rework' THEN '🔁 再作業'
    WHEN 'not_restored' THEN '🔴 復旧不可' ELSE '⏳ 確認中' END AS "復旧状態",
  CASE r.trial_run_status WHEN 'good' THEN '✅ 良好' WHEN 'recheck' THEN '🟡 要再確認' WHEN 'ng' THEN '🔴 NG' ELSE '—' END AS "試運転",
  CASE r.alarm_status WHEN 'cleared' THEN '✅ 解消' WHEN 'remaining' THEN '🔴 残あり' ELSE '—' END AS "アラーム",
  CASE r.scada_status WHEN 'normal' THEN '✅ 正常' WHEN 'abnormal' THEN '🔴 異常' WHEN 'unchecked' THEN '— 未確認' ELSE '—' END AS "SCADA",
  CASE r.generation_restart_status WHEN 'ok' THEN '✅ 可' WHEN 'no' THEN '🔴 不可' WHEN 'conditional' THEN '🟡 条件付き' ELSE '—' END AS "発電再開",
  CASE r.chief_review_status WHEN 'confirmed' THEN '✅ 済' WHEN 'pending' THEN '🟡 待ち' WHEN 'rejected' THEN '🔴 差戻し' ELSE '—' END AS "主任確認",
  COALESCE(NULLIF(r.checked_by_name,''),'—') AS "確認者",
  (r.checked_at AT TIME ZONE 'Asia/Tokyo') AS "確認日時",
  r.final_downtime_minutes AS "確定停止min", r.final_lost_kwh AS "確定逸失kwh", r.final_lost_revenue_yen AS "確定逸失円",
  array_to_string(array_remove(ARRAY[
    CASE WHEN r.restoration_status='rework' THEN '🔁 再作業' END,
    CASE WHEN r.restoration_status='not_restored' THEN '🔴 復旧不可' END,
    CASE WHEN r.trial_run_status='ng' THEN '⚠ 試運転NG' END,
    CASE WHEN r.alarm_status='remaining' THEN '⚠ アラーム残' END,
    CASE WHEN r.generation_restart_status='no' THEN '⛔ 発電不可' END,
    CASE WHEN r.chief_review_status='pending' THEN '🟡 主任待ち' END
  ], NULL), ' / ') AS "重要事項",
  r.execution_result_id, r.created_at
FROM restoration_checks r
JOIN work_orders wo ON wo.id=r.work_order_id
LEFT JOIN turbines t ON t.id=wo.turbine_id
ORDER BY r.created_at DESC;

DROP VIEW IF EXISTS v_closeout_review_list;
CREATE VIEW v_closeout_review_list AS
SELECT c.id, c.work_order_id,
  wo.work_order_no AS "作業票番号", t.turbine_no AS "風車", c.review_status,
  CASE c.review_status WHEN 'closed' THEN '✅ クローズ済' WHEN 'in_review' THEN '🔍 確認中'
    WHEN 'returned' THEN '↩ 差戻し' ELSE '📋 未確認' END AS "クローズ状態",
  CASE rc.restoration_status WHEN 'restored' THEN '✅ 復旧済' WHEN 'rework' THEN '🔁 再作業'
    WHEN 'not_restored' THEN '🔴 復旧不可' WHEN 'pending' THEN '⏳ 確認中' ELSE '—' END AS "復旧状態",
  c.report_required AS "報告要否", c.report_type AS "報告種別", c.report_deadline AS "報告期限",
  CASE c.evidence_status WHEN 'confirmed' THEN '✅ 確認済' ELSE '⚠ 不足' END AS "証跡",
  c.permit_closed AS "PTW終了", c.loto_released AS "LOTO解除",
  c.recurrence_action_required AS "再発防止要", c.remaining_issue AS "残課題",
  COALESCE(NULLIF(c.closed_by_name,''),'—') AS "確認者",
  (c.closed_at AT TIME ZONE 'Asia/Tokyo') AS "クローズ日時",
  array_to_string(array_remove(ARRAY[
    CASE WHEN c.report_required THEN '⚖ 報告要' END,
    CASE WHEN c.report_required AND c.report_deadline IS NOT NULL AND c.report_deadline < current_date AND c.review_status<>'closed' THEN '🟥 報告期限超過' END,
    CASE WHEN c.evidence_status='insufficient' THEN '⚠ 証跡不足' END,
    CASE WHEN c.permit_closed=false THEN '🔒 PTW未終了' END,
    CASE WHEN c.loto_released=false THEN '🔒 LOTO未解除' END,
    CASE WHEN c.recurrence_action_required THEN '🔁 再発防止要' END,
    CASE WHEN NULLIF(c.remaining_issue,'') IS NOT NULL THEN '📌 残課題あり' END
  ], NULL), ' / ') AS "重要事項",
  c.defect_finding_id, c.restoration_check_id, c.created_at
FROM closeout_reviews c
JOIN work_orders wo ON wo.id=c.work_order_id
LEFT JOIN turbines t ON t.id=wo.turbine_id
LEFT JOIN restoration_checks rc ON rc.id=c.restoration_check_id
ORDER BY c.created_at DESC;

-- =====================================================================
--  ビュー定義（実DBから取得した最新 / pg_get_viewdef）
-- =====================================================================

-- VIEW: v_work_order_safety_status
CREATE OR REPLACE VIEW v_work_order_safety_status AS  SELECT wo.id AS work_order_id,
    wo.work_order_no, wo.turbine_id, t.turbine_no, wo.work_type,
    wo.status AS wo_status, wo.approval_status,
    COALESCE(wo.ky_required, false) AS ky_required,
    ky.cnt > 0 AS ky_completed, ky.completed_at AS ky_completed_at,
    ky.completed_by AS ky_completed_by, ky.completed_by_name AS ky_completed_by_name,
    COALESCE(wo.ptw_required, false) AS ptw_required,
    ptw.cur_status AS ptw_status,
    ptw.cur_status = 'approved' AS ptw_approved_for_start,
    ptw.cur_status = 'closed' AS ptw_closed,
    ptw.approved_at AS ptw_approved_at, ptw.permit_no AS ptw_permit_no,
    COALESCE(wo.loto_required, false) AS loto_required,
    loto.lock_cnt > 0 AS loto_locked, loto.locked_at AS loto_locked_at,
    loto.unlock_cnt > 0 AS loto_unlocked, loto.unlocked_at AS loto_unlocked_at,
    (NOT COALESCE(wo.ky_required,false) OR ky.cnt>0) AND (NOT COALESCE(wo.ptw_required,false) OR ptw.cur_status='approved') AND (NOT COALESCE(wo.loto_required,false) OR loto.lock_cnt>0) AS safety_ready_to_start,
    (NOT COALESCE(wo.ky_required,false) OR ky.cnt>0) AND (NOT COALESCE(wo.ptw_required,false) OR (ptw.cur_status = ANY (ARRAY['approved','closed']))) AND (NOT COALESCE(wo.loto_required,false) OR loto.lock_cnt>0) AND (NOT COALESCE(wo.loto_required,false) OR loto.unlock_cnt>0) AS safety_ready_to_close,
    array_remove(ARRAY[
        CASE WHEN COALESCE(wo.ky_required,false) AND NOT ky.cnt>0 THEN 'KY未実施' END,
        CASE WHEN COALESCE(wo.ptw_required,false) AND (COALESCE(ptw.cur_status,'') <> ALL (ARRAY['approved','closed'])) THEN 'PTW未承認' END,
        CASE WHEN COALESCE(wo.loto_required,false) AND NOT loto.lock_cnt>0 THEN 'LOTO未施錠' END,
        CASE WHEN COALESCE(wo.loto_required,false) AND loto.lock_cnt>0 AND NOT loto.unlock_cnt>0 THEN 'LOTO未解除' END], NULL) AS blocking_reasons
   FROM work_orders wo
     LEFT JOIN turbines t ON t.id = wo.turbine_id
     LEFT JOIN LATERAL ( SELECT count(*) cnt, max(k.confirmed_at) completed_at,
            (array_agg(k.team_leader ORDER BY k.confirmed_at DESC NULLS LAST))[1] completed_by,
            (array_agg(ou.name ORDER BY k.confirmed_at DESC NULLS LAST))[1] completed_by_name
           FROM ky_records k LEFT JOIN om_users ou ON ou.id = k.team_leader
          WHERE k.work_order_id = wo.id AND k.confirmed_at IS NOT NULL) ky ON true
     LEFT JOIN LATERAL ( SELECT (array_agg(wp.permit_status ORDER BY wp.created_at DESC NULLS LAST))[1] cur_status,
            (array_agg(wp.permit_no ORDER BY wp.created_at DESC NULLS LAST))[1] permit_no, max(wp.approved_at) approved_at
           FROM work_permits wp WHERE wp.work_order_id = wo.id) ptw ON true
     LEFT JOIN LATERAL ( SELECT count(*) lock_cnt, min(l.created_at) locked_at,
            count(*) FILTER (WHERE l.status='unlocked') unlock_cnt, max(l.unlock_confirmed_at) unlocked_at
           FROM loto_records l WHERE l.work_order_id = wo.id) loto ON true;

-- ※ v_rca_list / v_work_execution_list / v_restoration_check_list / v_closeout_review_list
--    は本ファイル先頭のテーブル定義に対応する一覧ビュー。各CASEで業務名・絵文字に整形。
--    最新の正本は Supabase 上の定義（pg_get_viewdef）を参照のこと。
