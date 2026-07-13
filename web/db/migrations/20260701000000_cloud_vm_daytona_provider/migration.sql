-- Add the Daytona provider to the vm_provider enum. PostgreSQL 12+ allows ADD VALUE inside a
-- transaction as long as the new value is not used in the same transaction, which holds here.
ALTER TYPE "vm_provider" ADD VALUE IF NOT EXISTS 'daytona';
