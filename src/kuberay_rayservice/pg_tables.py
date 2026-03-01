import os
import sys
import logging
import asyncio
import asyncpg

logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper()),
    format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s","logger":"%(name)s"}',
    datefmt="%Y-%m-%dT%H:%M:%S%z"
)
logger = logging.getLogger("pg_tables")

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    logger.error("DATABASE_URL environment variable required")
    sys.exit(1)

async def init_db():
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=10)
        logger.info("connected.to.postgres")
        
        await conn.execute("""
            CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
            CREATE EXTENSION IF NOT EXISTS "pg_trgm";
        """)
        
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                email TEXT NOT NULL UNIQUE,
                provider TEXT NOT NULL,
                name TEXT,
                allowed_orgs TEXT[] DEFAULT ARRAY[]::TEXT[],
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
        """)
        
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS approvals (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                session_id UUID NOT NULL,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                tool_name TEXT NOT NULL,
                tool_args JSONB NOT NULL,
                reason TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
                resolved_by UUID REFERENCES users(id),
                resolved_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_approvals_session ON approvals(session_id);
            CREATE INDEX IF NOT EXISTS idx_approvals_status ON approvals(status) WHERE status = 'pending';
        """)
        
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS audit_logs (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                timestamp TIMESTAMPTZ DEFAULT NOW(),
                user_id UUID REFERENCES users(id),
                session_id UUID,
                action TEXT NOT NULL,
                details JSONB NOT NULL,
                ip_address INET
            );
            CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_logs(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_audit_session ON audit_logs(session_id);
        """)
        
        logger.info("database.schema.verified")
        await conn.close()
    except Exception as e:
        logger.error("database.initialization.failed", extra={"error": str(e)})
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(init_db())