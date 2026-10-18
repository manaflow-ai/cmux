-- Register the shared Huge Blue host as a first-class VM provider. Existing
-- rows remain Freestyle; the value is additive and safe on staging branches.
ALTER TYPE "vm_provider" ADD VALUE IF NOT EXISTS 'huge-blue';
