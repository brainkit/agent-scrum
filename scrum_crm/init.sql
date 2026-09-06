PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS tasks (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  title           TEXT NOT NULL,
  description     TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'BACKLOG'
                  CHECK (status IN ('BACKLOG','PLANNING','READY_FOR_DEV','CODING',
                                    'READY_FOR_REVIEW','REVIEWING',
                                    'READY_FOR_TEST','TESTING',
                                    'READY_FOR_DOCS','DOCUMENTING','DONE',
                                    'BLOCKED','CANCELLED')),
  priority        INTEGER NOT NULL DEFAULT 0,
  loop_count      INTEGER NOT NULL DEFAULT 0,
  assigned_agent  TEXT,
  locked_at       TEXT,
  holder_pid      INTEGER,
  holder_start    TEXT,
  summary         TEXT,
  error_log_path  TEXT,
  resolution_hint TEXT
);

CREATE TABLE IF NOT EXISTS task_files (
  task_id INTEGER NOT NULL REFERENCES tasks(id),
  path    TEXT    NOT NULL,
  PRIMARY KEY (task_id, path)
);

CREATE TABLE IF NOT EXISTS task_deps (
  task_id       INTEGER NOT NULL REFERENCES tasks(id),
  depends_on_id INTEGER NOT NULL REFERENCES tasks(id),
  PRIMARY KEY (task_id, depends_on_id),
  CHECK (task_id <> depends_on_id)
);

CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    INTEGER REFERENCES tasks(id),
  agent      TEXT NOT NULL,
  kind       TEXT NOT NULL,
  detail     TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TRIGGER IF NOT EXISTS enforce_status_flow
BEFORE UPDATE OF status ON tasks
WHEN NOT (
     (OLD.status='BACKLOG'          AND NEW.status IN ('PLANNING','CANCELLED'))
  OR (OLD.status='PLANNING'         AND NEW.status IN ('READY_FOR_DEV','BACKLOG','CANCELLED'))
  OR (OLD.status='READY_FOR_DEV'    AND NEW.status IN ('CODING','CANCELLED'))
  OR (OLD.status='CODING'           AND NEW.status IN ('READY_FOR_REVIEW','READY_FOR_TEST','READY_FOR_DEV','BLOCKED'))
  OR (OLD.status='READY_FOR_REVIEW' AND NEW.status IN ('REVIEWING'))
  OR (OLD.status='REVIEWING'        AND NEW.status IN ('READY_FOR_TEST','READY_FOR_REVIEW','READY_FOR_DEV'))
  OR (OLD.status='READY_FOR_TEST'   AND NEW.status IN ('TESTING','READY_FOR_DEV'))
  OR (OLD.status='TESTING'          AND NEW.status IN ('READY_FOR_DOCS','READY_FOR_TEST','READY_FOR_DEV'))
  OR (OLD.status='READY_FOR_DOCS'   AND NEW.status IN ('DOCUMENTING'))
  OR (OLD.status='DOCUMENTING'      AND NEW.status IN ('DONE','READY_FOR_DOCS','READY_FOR_DEV'))
  OR (OLD.status='BLOCKED'          AND NEW.status IN ('PLANNING','CANCELLED'))
  OR (OLD.status=NEW.status)
)
BEGIN
  SELECT RAISE(ABORT, 'Invalid status transition');
END;

-- Every status change is logged mechanically — the task's full journey
-- is reconstructible from events (kind='status') without trusting any
-- agent to remember to log it.
CREATE TRIGGER IF NOT EXISTS log_status_transition
AFTER UPDATE OF status ON tasks
WHEN OLD.status <> NEW.status
BEGIN
  INSERT INTO events (task_id, agent, kind, detail)
  VALUES (NEW.id, COALESCE(NEW.assigned_agent, OLD.assigned_agent, 'system'),
          'status', OLD.status || ' -> ' || NEW.status);
END;

-- A task never lands in BLOCKED without a stated reason: the same UPDATE
-- must carry a non-empty resolution_hint (crm.mjs advance enforces --hint
-- CLI-side; this trigger is the backstop for any other write path).
CREATE TRIGGER IF NOT EXISTS enforce_blocked_reason
BEFORE UPDATE OF status ON tasks
WHEN NEW.status='BLOCKED' AND OLD.status<>'BLOCKED'
     AND (NEW.resolution_hint IS NULL OR trim(NEW.resolution_hint)='')
BEGIN
  SELECT RAISE(ABORT, 'BLOCKED requires a reason: set resolution_hint in the same update (advance ID BLOCKED --hint "why")');
END;
