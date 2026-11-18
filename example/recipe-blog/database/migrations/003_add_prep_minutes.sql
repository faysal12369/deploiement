-- A new column: run once on each target by the next deployment, recorded in its _deploy_migrations table.
ALTER TABLE recipes ADD COLUMN prep_minutes SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER category_id;
