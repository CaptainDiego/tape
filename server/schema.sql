CREATE TABLE IF NOT EXISTS shares (
  id         TEXT PRIMARY KEY,           -- 12 random base62 characters
  title      TEXT NOT NULL,
  duration   REAL NOT NULL DEFAULT 0,    -- seconds
  created_at INTEGER NOT NULL,           -- unix ms
  version    INTEGER NOT NULL DEFAULT 0, -- unix ms of the last finished upload; 0 = not ready
  views      INTEGER NOT NULL DEFAULT 0
);
