-- 初始化在主库上创建，复制会同步到从库
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'srcheck') THEN
    CREATE ROLE srcheck LOGIN PASSWORD 'srcheckpass';
    -- PostgreSQL 10+：授予只读监控权限即可满足 Pgpool 的延迟检查
    GRANT pg_monitor TO srcheck;
  END IF;
END
$$;

