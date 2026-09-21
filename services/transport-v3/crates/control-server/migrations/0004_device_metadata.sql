-- Nullable for existing enrollments and old clients. Missing metadata never
-- implies a pairable Mac; upgraded clients republish signed metadata on enroll.
ALTER TABLE transport_v3_devices ADD COLUMN metadata JSONB;
ALTER TABLE transport_v3_devices ADD CONSTRAINT transport_v3_device_metadata_object
    CHECK (metadata IS NULL OR jsonb_typeof(metadata) = 'object');
