// Single door to crm.db — every command opens/queries/closes through this
// module (mirrors the previous db.mjs subprocess contract, now in-process).
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';

const RETURNING_OR_SELECT = /^\s*(SELECT|WITH)\b/i;
const RETURNING_CLAUSE = /\bRETURNING\b/i;
const INTEGER_LITERAL = /^-?[0-9]+$/;

// Coerce only for read-only SELECT/WITH (not INSERT/UPDATE, even with
// RETURNING): comparisons like WHERE id=? lose the match if the parameter
// stays a string, but rewriting a numeric TEXT value (e.g. "007") on a
// write path would strip its original form before it reaches the column.
export function coerceParams(sql, params) {
  if (!RETURNING_OR_SELECT.test(sql)) {
    return params;
  }
  return params.map((param) => (typeof param === 'string' && INTEGER_LITERAL.test(param) ? Number(param) : param));
}

export function openDatabase(dbPath) {
  const database = new DatabaseSync(dbPath);
  database.exec('PRAGMA busy_timeout=30000;');
  database.exec('PRAGMA foreign_keys=ON;');
  return database;
}

export function runInit(dbPath, initSqlPath) {
  const database = openDatabase(dbPath);
  const initSql = readFileSync(initSqlPath, 'utf8');
  database.exec(initSql);
  database.close();
}

function statementReturnsRows(sql) {
  return RETURNING_OR_SELECT.test(sql) || RETURNING_CLAUSE.test(sql);
}

// Runs one statement on its own connection (open -> run -> close), same
// isolation the old per-call subprocess gave every db.sh invocation.
export function runQuery(dbPath, sql, params) {
  const database = openDatabase(dbPath);
  try {
    const statement = database.prepare(sql);
    const coercedParams = coerceParams(sql, params);
    return statementReturnsRows(sql) ? statement.all(...coercedParams) : (statement.run(...coercedParams), []);
  } finally {
    database.close();
  }
}

export function scalarFromRows(rows) {
  if (rows.length === 0) {
    return undefined;
  }
  const firstColumnValue = Object.values(rows[0])[0];
  return firstColumnValue === null || firstColumnValue === undefined ? '' : String(firstColumnValue);
}

export function runScalar(dbPath, sql, params) {
  return scalarFromRows(runQuery(dbPath, sql, params));
}
