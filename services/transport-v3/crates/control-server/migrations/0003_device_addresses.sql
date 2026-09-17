ALTER TABLE transport_v3_devices
  ADD COLUMN addresses JSONB NOT NULL DEFAULT '[]';
