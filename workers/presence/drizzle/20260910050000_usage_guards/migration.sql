CREATE TRIGGER account_bindings_usage_insert AFTER INSERT ON account_bindings BEGIN
  SELECT CASE WHEN
    (SELECT payload_bytes + NEW.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 OR
    (SELECT records + 1 FROM account_storage_usage WHERE id = 1) > 4096 OR
    (SELECT live_bindings + CASE WHEN NEW.revoked_at IS NULL THEN 1 ELSE 0 END FROM account_storage_usage WHERE id = 1) > 32
    THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes,
    records = records + 1,
    live_bindings = live_bindings + CASE WHEN NEW.revoked_at IS NULL THEN 1 ELSE 0 END WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_bindings_usage_delete AFTER DELETE ON account_bindings BEGIN
  UPDATE account_storage_usage SET payload_bytes = payload_bytes - OLD.payload_bytes,
    records = records - 1,
    live_bindings = live_bindings - CASE WHEN OLD.revoked_at IS NULL THEN 1 ELSE 0 END WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_bindings_usage_update AFTER UPDATE ON account_bindings BEGIN
  SELECT CASE WHEN
    (SELECT payload_bytes + NEW.payload_bytes - OLD.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 OR
    (SELECT records FROM account_storage_usage WHERE id = 1) > 4096 OR
    (SELECT live_bindings + CASE WHEN NEW.revoked_at IS NULL THEN 1 ELSE 0 END - CASE WHEN OLD.revoked_at IS NULL THEN 1 ELSE 0 END FROM account_storage_usage WHERE id = 1) > 32
    THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes - OLD.payload_bytes,
    live_bindings = live_bindings + CASE WHEN NEW.revoked_at IS NULL THEN 1 ELSE 0 END - CASE WHEN OLD.revoked_at IS NULL THEN 1 ELSE 0 END WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_challenges_usage_insert AFTER INSERT ON account_challenges BEGIN
  SELECT CASE WHEN (SELECT payload_bytes + NEW.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 OR (SELECT records + 1 FROM account_storage_usage WHERE id = 1) > 4096 THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes, records = records + 1 WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_challenges_usage_delete AFTER DELETE ON account_challenges BEGIN
  UPDATE account_storage_usage SET payload_bytes = payload_bytes - OLD.payload_bytes, records = records - 1 WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_challenges_usage_update AFTER UPDATE ON account_challenges BEGIN
  SELECT CASE WHEN (SELECT payload_bytes + NEW.payload_bytes - OLD.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes - OLD.payload_bytes WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_pair_grants_usage_insert AFTER INSERT ON account_pair_grants BEGIN
  SELECT CASE WHEN (SELECT payload_bytes + NEW.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 OR (SELECT records + 1 FROM account_storage_usage WHERE id = 1) > 4096 THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes, records = records + 1 WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_pair_grants_usage_delete AFTER DELETE ON account_pair_grants BEGIN
  UPDATE account_storage_usage SET payload_bytes = payload_bytes - OLD.payload_bytes, records = records - 1 WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_pair_grants_usage_update AFTER UPDATE ON account_pair_grants BEGIN
  SELECT CASE WHEN (SELECT payload_bytes + NEW.payload_bytes - OLD.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes - OLD.payload_bytes WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_relay_issuances_usage_insert AFTER INSERT ON account_relay_issuances BEGIN
  SELECT CASE WHEN (SELECT payload_bytes + NEW.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 OR (SELECT records + 1 FROM account_storage_usage WHERE id = 1) > 4096 THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes, records = records + 1 WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_relay_issuances_usage_delete AFTER DELETE ON account_relay_issuances BEGIN
  UPDATE account_storage_usage SET payload_bytes = payload_bytes - OLD.payload_bytes, records = records - 1 WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_relay_issuances_usage_update AFTER UPDATE ON account_relay_issuances BEGIN
  SELECT CASE WHEN (SELECT payload_bytes + NEW.payload_bytes - OLD.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes - OLD.payload_bytes WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_preferences_usage_insert AFTER INSERT ON account_preferences BEGIN
  SELECT CASE WHEN (SELECT payload_bytes + NEW.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 OR (SELECT records + 1 FROM account_storage_usage WHERE id = 1) > 4096 THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes, records = records + 1 WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_preferences_usage_delete AFTER DELETE ON account_preferences BEGIN
  UPDATE account_storage_usage SET payload_bytes = payload_bytes - OLD.payload_bytes, records = records - 1 WHERE id = 1;
END;
--> statement-breakpoint
CREATE TRIGGER account_preferences_usage_update AFTER UPDATE ON account_preferences BEGIN
  SELECT CASE WHEN (SELECT payload_bytes + NEW.payload_bytes - OLD.payload_bytes FROM account_storage_usage WHERE id = 1) > 8388608 THEN RAISE(ABORT, 'account storage quota exceeded') END;
  UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes - OLD.payload_bytes WHERE id = 1;
END;
