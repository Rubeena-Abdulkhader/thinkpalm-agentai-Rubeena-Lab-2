-- ============================================================================
-- Migration Script: seafarer_debriefs (with levels and level_members)
-- Legacy: synergy_seafarer.public.appraisal_debrief → New: smac_crewing_migration.shore.seafarer_debriefs, seafarer_debrief_levels, seafarer_debrief_level_members
-- Note: One source record splits into:
--   1. One row in seafarer_debriefs (main record)
--   2. Multiple rows in seafarer_debrief_levels (one per feedback array element)
--   3. Multiple rows in seafarer_debrief_level_members (one per debriefer in each feedback element)
--
-- DBLINK CONNECTIONS:
--   This script uses the following dblink connections (defined in 07-orchestration/00_common/connection_setup.sql):
--   1. 'synergy_seafarer' - Uses SS_HOST, SS_PORT, SS_DB, SS_USER, SS_PASS variables
--   2. 'synergy_vessel' - Uses SV_HOST, SV_PORT, SV_DB, SV_USER, SV_PASS variables
--   3. 'smac_master_migration' - Uses SMM_HOST, SMM_PORT, SMM_DB, SMM_USER, SMM_PASS variables (conditional)
--
--   Connection strings are built in connection_setup.sql using format():
--     format('host=%s port=%s dbname=%s user=%s password=%s', :'SS_HOST', :'SS_PORT', ...)
--
--   Variables are set by the PowerShell orchestration script (migrate_smac_crewing.ps1) from
--   migration_config_smac_crewing.json configuration file.
--
--   NOTE: All dblink queries use single-quoted strings. Single quotes inside queries are escaped as ''.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

\echo '=========================================='
\echo 'Migration: seafarer_debriefs (with levels and level_members)'
\echo '=========================================='

BEGIN;

-- Pre-migration checks
\echo 'Pre-migration checks...'

-- Verify dblink connections are established
\echo 'Verifying dblink connections...'
DO $$
DECLARE
    v_connections TEXT[];
    v_synergy_seafarer_ok BOOLEAN := false;
    v_synergy_vessel_ok BOOLEAN := false;
    v_smac_master_ok BOOLEAN := false;
BEGIN
    -- Get all active dblink connections
    SELECT dblink_get_connections() INTO v_connections;
    
    -- Check each required connection
    v_synergy_seafarer_ok := 'synergy_seafarer' = ANY(v_connections);
    v_synergy_vessel_ok := 'synergy_vessel' = ANY(v_connections);
    v_smac_master_ok := 'smac_master_migration' = ANY(v_connections);
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Dblink Connection Status:';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'synergy_seafarer: %', CASE WHEN v_synergy_seafarer_ok THEN 'CONNECTED' ELSE 'NOT CONNECTED' END;
    RAISE NOTICE 'synergy_vessel: %', CASE WHEN v_synergy_vessel_ok THEN 'CONNECTED' ELSE 'NOT CONNECTED' END;
    RAISE NOTICE 'smac_master_migration: %', CASE WHEN v_smac_master_ok THEN 'CONNECTED' ELSE 'NOT CONNECTED' END;
    RAISE NOTICE '========================================';
    
    -- Test connections with simple queries
    IF v_synergy_seafarer_ok THEN
        BEGIN
            PERFORM dblink('synergy_seafarer', 'SELECT 1');
            RAISE NOTICE 'synergy_seafarer connection test: OK';
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'synergy_seafarer connection test FAILED: %', SQLERRM;
        END;
    END IF;
    
    IF v_synergy_vessel_ok THEN
        BEGIN
            PERFORM dblink('synergy_vessel', 'SELECT 1');
            RAISE NOTICE 'synergy_vessel connection test: OK';
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'synergy_vessel connection test FAILED: %', SQLERRM;
        END;
    END IF;
    
    IF v_smac_master_ok THEN
        BEGIN
            PERFORM dblink('smac_master_migration', 'SELECT 1');
            RAISE NOTICE 'smac_master_migration connection test: OK';
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'smac_master_migration connection test FAILED: %', SQLERRM;
        END;
    END IF;
    
    -- Warn if critical connections are missing
    IF NOT v_synergy_seafarer_ok THEN
        RAISE WARNING 'CRITICAL: synergy_seafarer connection not established. Check connection_setup.sql and SS_* variables.';
    END IF;
    
    IF NOT v_synergy_vessel_ok THEN
        RAISE WARNING 'CRITICAL: synergy_vessel connection not established. Check connection_setup.sql and SV_* variables.';
    END IF;
    
    IF NOT v_smac_master_ok THEN
        RAISE WARNING 'WARNING: smac_master_migration connection not established. Check connection_setup.sql and SMM_* variables.';
    END IF;
END $$;

DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='shore' AND table_name='seafarer_debriefs') THEN
        RAISE EXCEPTION 'Target table shore.seafarer_debriefs does not exist. Please create the table schema first.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='shore' AND table_name='seafarer_debrief_levels') THEN
        RAISE EXCEPTION 'Target table shore.seafarer_debrief_levels does not exist. Please create the table schema first.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='shore' AND table_name='seafarer_debrief_level_members') THEN
        RAISE EXCEPTION 'Target table shore.seafarer_debrief_level_members does not exist. Please create the table schema first.';
    END IF;
    
    -- Verify prerequisite tables are migrated
    IF NOT EXISTS (SELECT 1 FROM migration.table_mappings WHERE target_table = 'seafarers' AND target_db = current_database()) THEN
        RAISE EXCEPTION 'seafarers table must be migrated first';
    END IF;
END $$;

\echo 'Legacy row count:'
DO $$
DECLARE
    v_legacy_count BIGINT;
BEGIN
    SELECT cnt INTO v_legacy_count FROM dblink('synergy_seafarer', 
        'SELECT COUNT(*) FROM public.appraisal_debrief'
    ) AS t(cnt bigint);
    RAISE NOTICE 'Legacy appraisal_debrief table row count: %', v_legacy_count;
    
    IF v_legacy_count = 0 THEN
        RAISE WARNING 'WARNING: No rows found in legacy appraisal_debrief table!';
    END IF;
END $$;

\echo 'Sample legacy data (first 5 rows):'
DO $$
DECLARE
    r RECORD;
    v_row_count INT := 0;
BEGIN
    FOR r IN 
        SELECT id, seafarer_uuid, vessel_uuid, vessel_category_id, debrief_status 
        FROM dblink('synergy_seafarer', 
            'SELECT id, seafarer_uuid, vessel_uuid, vessel_category_id, debrief_status FROM public.appraisal_debrief LIMIT 5'
        ) AS t(id uuid, seafarer_uuid uuid, vessel_uuid uuid, vessel_category_id bigint, debrief_status text)
    LOOP
        v_row_count := v_row_count + 1;
        RAISE NOTICE 'Row %: id=%, seafarer_uuid=%, vessel_uuid=%, vessel_category_id=%, debrief_status=%', 
            v_row_count, r.id, r.seafarer_uuid, r.vessel_uuid, r.vessel_category_id, r.debrief_status;
    END LOOP;
    
    IF v_row_count = 0 THEN
        RAISE WARNING 'WARNING: No sample rows returned from dblink query!';
    END IF;
END $$;

\echo 'Target table current counts:'
SELECT COUNT(*) AS debriefs_count FROM shore.seafarer_debriefs;
SELECT COUNT(*) AS levels_count FROM shore.seafarer_debrief_levels;
SELECT COUNT(*) AS members_count FROM shore.seafarer_debrief_level_members;

-- Check for existing data warning
DO $$
DECLARE
    v_existing_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_existing_count FROM shore.seafarer_debriefs;
    IF v_existing_count > 0 THEN
        RAISE WARNING 'Target tables contain existing records. These will be deleted!';
    END IF;
END $$;

-- Clear existing data from target tables
TRUNCATE TABLE shore.seafarer_debrief_level_members;
TRUNCATE TABLE shore.seafarer_debrief_levels;
TRUNCATE TABLE shore.seafarer_debriefs;
-- Delete mappings from migration.table_mappings
DELETE FROM migration.table_mappings 
WHERE target_table IN ('seafarer_debriefs', 'seafarer_debrief_levels', 'seafarer_debrief_level_members')
  AND target_db = current_database();

-- Create lookup tables for foreign key resolution
\echo 'Creating lookup tables for foreign key resolution...'

-- Create seafarer_id lookup mapping (source has seafarer_uuid as uuid, target needs uuid from mapping)
-- Note: seafarer_uuid is a UUID, so we should match directly with seafarers.id if UUIDs were preserved
-- Strategy: Direct UUID match (primary) - seafarer_uuid should match seafarers.id directly
-- Fallback: Use mapping table only for UUID source_ids (if seafarers preserved UUIDs in mapping table)
CREATE TEMP TABLE seafarer_uuid_mapping AS
SELECT 
    source_id::uuid as legacy_uuid,
    target_id as new_id
FROM migration.table_mappings
WHERE target_table = 'seafarers'
  AND target_db = current_database()
  AND source_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';  -- UUID pattern

-- Vessel: legacy vessel_id (bigint) → smac vessel.vessels.id via smac_master migration.table_mappings;
-- debrief_vessel_lookup: appraisal_debrief.vessel_uuid = vessel_details.identifier → legacy vessel_id;
-- vessel_revision_mapping: active revision per vessel (status=0, newest by created_at)

CREATE TEMP TABLE vessel_id_mapping AS
SELECT
    source_id::bigint AS legacy_id,
    target_id AS new_id
FROM dblink('smac_master_migration',
    'SELECT source_id, target_id FROM migration.table_mappings WHERE target_table = ''vessels'' AND source_id ~ ''^[0-9]+$'''
) AS t(source_id text, target_id uuid)
WHERE source_id IS NOT NULL AND target_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_vessel_id_mapping_legacy_id ON vessel_id_mapping(legacy_id);

-- Bridge vessel_uuid to synergy_vessel legacy vessel_id (bigint) for vessel_id_mapping
CREATE TEMP TABLE debrief_vessel_lookup AS
SELECT DISTINCT
    vd.identifier AS legacy_vessel_identifier,
    vd.vessel_id AS legacy_vessel_id
FROM dblink('synergy_vessel',
    'SELECT identifier, vessel_id FROM public.vessel_details WHERE identifier IS NOT NULL AND vessel_id IS NOT NULL'
) AS vd(identifier uuid, vessel_id bigint);

CREATE INDEX IF NOT EXISTS idx_debrief_vessel_lookup_identifier ON debrief_vessel_lookup(legacy_vessel_identifier);

\echo 'Creating vessel_revision_mapping for active revisions (seafarer_reliefs pattern)...'
CREATE TEMP TABLE vessel_revision_mapping AS
SELECT DISTINCT ON (vr.vessel_id)
    vr.vessel_id AS new_vessel_id,
    vr.id AS active_revision_id
FROM dblink('smac_master_migration',
    'SELECT id, vessel_id, status, created_at
     FROM vessel.vessel_revisions
     WHERE status = 0
     ORDER BY vessel_id, created_at DESC'
) AS vr(id uuid, vessel_id uuid, status integer, created_at timestamp)
INNER JOIN (
    SELECT new_id AS vessel_id FROM vessel_id_mapping
) AS all_vessels ON all_vessels.vessel_id = vr.vessel_id
ORDER BY vr.vessel_id, vr.created_at DESC;

\echo 'Vessel revision mapping row count:'
SELECT COUNT(*) AS vessel_revision_lookup_count FROM vessel_revision_mapping;

\echo 'Vessel mapping diagnostic (debrief_vessel_lookup + vessel_id_mapping + vessel_revision_mapping):'
DO $$
DECLARE
    v_lookup_count BIGINT;
    v_vid_count BIGINT;
    v_vrev_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_lookup_count FROM debrief_vessel_lookup;
    SELECT COUNT(*) INTO v_vid_count FROM vessel_id_mapping;
    SELECT COUNT(*) INTO v_vrev_count FROM vessel_revision_mapping;
    RAISE NOTICE 'debrief_vessel_lookup rows: % (identifier to legacy vessel_id)', v_lookup_count;
    RAISE NOTICE 'vessel_id_mapping rows: %', v_vid_count;
    RAISE NOTICE 'vessel_revision_mapping rows: %', v_vrev_count;
END $$;

-- Create vessel_type_id lookup mapping (vessel_category_id bigint → vessel_type_id uuid)
-- Strategy: Map vessel_category_id (bigint) from appraisal_debrief to categories.id (uuid) using migration.table_mappings
-- Note: categories table was migrated from vessel_categories, so source_id = vessel_categories.id (bigint), target_id = categories.id (uuid)
CREATE TEMP TABLE vessel_type_id_mapping AS
SELECT 
    source_id::bigint as legacy_category_id,
    target_id as new_type_id
FROM dblink('smac_master_migration',
    'SELECT source_id, target_id FROM migration.table_mappings WHERE target_table ILIKE ''categories'''
) AS t(source_id text, target_id uuid);

-- ============================================================================
-- STEP 1: Migrate seafarer_debriefs (main table)
-- ============================================================================
\echo 'Step 1: Migrating seafarer_debriefs data...'

-- Test dblink query first
\echo 'Testing dblink query...'
DO $$
DECLARE
    v_test_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_test_count FROM dblink('synergy_seafarer', 
        'SELECT COUNT(*) FROM public.appraisal_debrief'
    ) AS t(cnt bigint);
    RAISE NOTICE 'Dblink test query returned: % rows', v_test_count;
    
    IF v_test_count IS NULL THEN
        RAISE EXCEPTION 'ERROR: dblink query returned NULL. Check connection!';
    END IF;
END $$;

INSERT INTO shore.seafarer_debriefs (
    id,
    seafarer_id,
    seafarer_assignment_id,
    appraisal_id,
    reason_id,
    reason_text,
    vessel_id,
    vessel_type_id,
    sign_on_date,
    sign_off_date,
    appraisal_reports_available,
    attachments,
    current_stage,
    workflow_status,
    initiated_by,
    initiated_at,
    closed_by,
    closed_at,
    status,
    tenant_id,
    created_at,
    updated_at,
    archived_at,
    deleted_at,
    audit_info,
    vessel_revision_id
)
SELECT 
    legacy_data.id as id,  -- Preserve legacy UUID id directly
    legacy_data.seafarer_uuid as seafarer_id,  -- Map seafarer_uuid to seafarer_id with fallbacks
    NULL as seafarer_assignment_id,  -- Not available in source
    NULL as appraisal_id,  -- Not available in source
    legacy_data.debrief_reason_id as reason_id,  -- Direct UUID mapping
    TRIM(legacy_data.other_debrief_reason) as reason_text,  -- Direct copy
    vessel_map.new_id as vessel_id,  -- legacy vessel_id (via debrief_vessel_lookup) -> smac vessels.id
    COALESCE(vessel_type_map.new_type_id, '00000000-0000-0000-0000-000000000000'::uuid) as vessel_type_id,  -- Map vessel_category_id to vessel_type_id via mapping, default to empty UUID if not found
    legacy_data.from_date::date as sign_on_date,  -- Convert timestamp to date
    legacy_data.to_date::date as sign_off_date,  -- Convert timestamp to date
    false as appraisal_reports_available,  -- Default to false (NOT NULL)
    CASE 
        WHEN legacy_data.attachments IS NULL OR array_length(legacy_data.attachments, 1) IS NULL THEN NULL
        ELSE to_jsonb(legacy_data.attachments)
    END as attachments,  -- Convert text[] to jsonb
    -- current_stage: map SAC appraisal_debrief.debrief_status to SMAC stage values
    CASE LOWER(TRIM(COALESCE(legacy_data.debrief_status, '')))
        WHEN 'debriefing_initiated' THEN 'DebriefInitiated'
        WHEN 'ncs_review_1_initiated' THEN 'NCSReview1Initiated'
        WHEN 'ncs_review_1_recommended' THEN 'NCSReview1Recommended'
        WHEN 'ncs_review_2_recommended' THEN 'NCSReview2Recommended'
        WHEN 'debriefing_closed' THEN 'Closed'
        WHEN 'draft' THEN 'Draft'
        ELSE COALESCE(NULLIF(TRIM(legacy_data.debrief_status), ''), 'Draft')
    END as current_stage,
    -- Extract first feedback element's status for workflow_status
    CASE 
        WHEN legacy_data.feedback IS NOT NULL 
         AND jsonb_typeof(legacy_data.feedback) = 'array' 
         AND jsonb_array_length(legacy_data.feedback) > 0
         AND legacy_data.feedback->0->>'status' IS NOT NULL
        THEN legacy_data.feedback->0->>'status'
        ELSE NULL
    END as workflow_status,
    NULL::uuid as initiated_by,  -- User mapping not available, set to NULL
    COALESCE(legacy_data.initiated_date, legacy_data.created_at) as initiated_at,  -- Prefer initiated_date, fallback to created_at
    NULL::uuid as closed_by,  -- User mapping not available, set to NULL
    CASE 
        WHEN LOWER(TRIM(COALESCE(legacy_data.debrief_status, ''))) IN ('debriefing_closed', 'closed', 'completed', 'finished') THEN legacy_data.updated_at
        ELSE NULL
    END as closed_at,  -- Set when debrief is closed (SAC debriefing_Closed or legacy closed states)
    'Active' as status,  -- Always Active per migration rules (NOT NULL)
    :'DEFAULT_TENANT_ID'::uuid as tenant_id,  -- See constants.sql for DEFAULT_TENANT_ID
    COALESCE(legacy_data.created_at, NOW()) as created_at,  -- Default to current timestamp
    COALESCE(legacy_data.updated_at, NOW()) as updated_at,  -- Default to current timestamp
    NULL as archived_at,  -- Not in source
    legacy_data.deleted_at as deleted_at,  -- Direct copy
    jsonb_build_object(
        -- SMAC audit_info structure
        'created_by', CASE WHEN legacy_data.created_by_id IS NOT NULL AND legacy_data.created_by_id::text <> '' THEN legacy_data.created_by_id::text ELSE NULL END,
        'deleted_by', CASE WHEN legacy_data.deleted_by IS NOT NULL AND legacy_data.deleted_by::text <> '' THEN legacy_data.deleted_by::text ELSE NULL END,
        'updated_by', CASE WHEN legacy_data.updated_by_id IS NOT NULL AND legacy_data.updated_by_id::text <> '' THEN legacy_data.updated_by_id::text ELSE NULL END,
        'archived_by', NULL,
        'submitted_by', NULL,
        'approved_at', NULL,
        'approved_by', NULL,
        'approval_notes', NULL,
        'rejected_by', NULL,
        'notes', NULL,
        -- Legacy migration metadata (preserved for reference)
        'legacy_id', legacy_data.id::text
    ) as audit_info,
    COALESCE(vrm.active_revision_id, '00000000-0000-0000-0000-000000000000'::uuid) as vessel_revision_id
FROM dblink('synergy_seafarer', 
    'SELECT 
        id,
        seafarer_uuid,
        initiated_date,
        debrief_reason_id,
        other_debrief_reason,
        rank_id,
        vessel_category_id,
        vessel_uuid,
        attachments,
        debrief_status,
        from_date,
        to_date,
        mark_for_deactivation,
        is_manual,
        training_needs,
        feedback,
        deleted_at,
        deleted_by,
        created_by_id,
        created_by_name,
        created_at,
        updated_by_id,
        updated_by_name,
        updated_at
     FROM public.appraisal_debrief
     WHERE feedback IS NOT NULL 
       AND jsonb_typeof(feedback) = ''array''
       AND jsonb_array_length(feedback) > 0'
) AS legacy_data(
    id uuid,
    seafarer_uuid uuid,
    initiated_date timestamp without time zone,
    debrief_reason_id uuid,
    other_debrief_reason text,
    rank_id bigint,
    vessel_category_id bigint,
    vessel_uuid uuid,
    attachments text[],
    debrief_status text,
    from_date timestamp without time zone,
    to_date timestamp without time zone,
    mark_for_deactivation boolean,
    is_manual boolean,
    training_needs jsonb,
    feedback jsonb,
    deleted_at timestamp without time zone,
    deleted_by text,
    created_by_id text,
    created_by_name varchar,
    created_at timestamp without time zone,
    updated_by_id text,
    updated_by_name varchar,
    updated_at timestamp without time zone
)
LEFT JOIN debrief_vessel_lookup v_bridge ON v_bridge.legacy_vessel_identifier = legacy_data.vessel_uuid
LEFT JOIN vessel_id_mapping vessel_map ON vessel_map.legacy_id = v_bridge.legacy_vessel_id
LEFT JOIN vessel_revision_mapping vrm ON vrm.new_vessel_id = vessel_map.new_id
LEFT JOIN vessel_type_id_mapping vessel_type_map ON vessel_type_map.legacy_category_id = legacy_data.vessel_category_id
WHERE vessel_map.new_id IS NOT NULL;
-- vessel_type_id via vessel_type_id mapping (can be default UUID when unmapped)

-- Check insert count immediately
\echo 'Checking insert count...'
DO $$
DECLARE
    v_inserted_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_inserted_count FROM shore.seafarer_debriefs;
    RAISE NOTICE 'Rows inserted so far: %', v_inserted_count;
    
    IF v_inserted_count = 0 THEN
        RAISE WARNING 'WARNING: INSERT completed but no rows found in target table!';
        RAISE WARNING 'This could indicate:';
        RAISE WARNING '  1. Source table is empty';
        RAISE WARNING '  2. INSERT failed silently (check constraints/errors)';
        RAISE WARNING '  3. Transaction rolled back';
    END IF;
END $$;

-- Post-migration validation
\echo 'Post-migration validation...'
DO $$
DECLARE
    v_inserted_count BIGINT;
    v_legacy_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_inserted_count FROM shore.seafarer_debriefs;
    
    SELECT cnt INTO v_legacy_count FROM dblink('synergy_seafarer', 
        'SELECT COUNT(*) FROM public.appraisal_debrief'
    ) AS t(cnt bigint);
    
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Migration Summary:';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Legacy rows: %', v_legacy_count;
    RAISE NOTICE 'Inserted rows: %', v_inserted_count;
    
    IF v_inserted_count = 0 AND v_legacy_count > 0 THEN
        RAISE WARNING 'ERROR: No rows inserted but legacy table has % rows!', v_legacy_count;
    ELSIF v_inserted_count != v_legacy_count THEN
        RAISE WARNING 'WARNING: Row count mismatch! Legacy: %, Inserted: %', v_legacy_count, v_inserted_count;
    ELSE
        RAISE NOTICE 'SUCCESS: All rows migrated correctly';
    END IF;
    RAISE NOTICE '========================================';
END $$;

\echo 'Migration completed: seafarer_debriefs (with levels and level_members)'

COMMIT;