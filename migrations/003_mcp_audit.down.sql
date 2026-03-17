DROP INDEX IF EXISTS idx_support_replies_ticket;
DROP TABLE IF EXISTS support_replies;
DROP INDEX IF EXISTS idx_refunds_payment;
DROP TABLE IF EXISTS refunds;
DROP INDEX IF EXISTS idx_tool_calls_created_at;
DROP INDEX IF EXISTS idx_tool_calls_run;
DROP INDEX IF EXISTS ux_tool_calls_tool_and_idempotency;
DROP TABLE IF EXISTS tool_calls;