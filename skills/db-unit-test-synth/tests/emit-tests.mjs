// Robustness tests for emit-tsqlt.mjs — run on the host (node).
// Focus: quote/injection escaping, type formatting, the "never fabricate an expected" rule,
// the tSQLt "test" prefix requirement, and determinism.
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const EMIT = '.claude/skills/db-unit-test-synth/scripts/emit-tsqlt.mjs';
const dir = mkdtempSync(join(tmpdir(), 'emit-'));
let pass = 0, fail = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS ' : 'FAIL '} ${name}${detail ? '  -> ' + detail : ''}`); ok ? pass++ : fail++; };

function emit(fixture, args = []) {
  const p = join(dir, 'f.json');
  writeFileSync(p, JSON.stringify(fixture));
  return execFileSync('node', [EMIT, p, ...args], { encoding: 'utf8' });
}

const baseTables = [{
  schema: 'route', table: 'T', columns: [
    { name: 'Id', type: 'int' }, { name: 'Name', type: 'nvarchar' }, { name: 'Flag', type: 'bit' },
    { name: 'When', type: 'datetime2' }, { name: 'Amt', type: 'decimal' },
  ],
}];
const base = (branches) => ({
  object: 'route.fnX', db: 'AppDb_Dev', type: 'SQL_SCALAR_FUNCTION',
  signature: [], fake: [{ schema: 'route', table: 'T' }], tables: baseTables,
  fk_closure: [], checks: [], definition: 'x', branches,
});

// --- 1. SQL injection / quote escaping in a seed value
{
  const evil = "Robert'); DROP TABLE route.T; --";
  const out = emit(base([{
    id: 'injection', seed: [{ table: 'route.T', row: { Id: 1, Name: evil } }],
    assert: { actual_expr: 'SELECT 1', expected: 1 }, needs_human_oracle: false,
  }]));
  check('injection: single quotes are doubled (escaped)', out.includes("N'Robert''); DROP TABLE route.T; --'"), );
  check('injection: no unescaped break-out of the string literal',
        !/VALUES \(1, N'Robert'\); DROP/.test(out));
}

// --- 2. Type formatting: NULL, bit, numeric, date, string
{
  const out = emit(base([{
    id: 'types', seed: [{ table: 'route.T', row: { Id: 7, Name: null, Flag: true, When: '2026-01-02', Amt: 12.5 } }],
    assert: { actual_expr: 'SELECT 1', expected: 1 }, needs_human_oracle: false,
  }]));
  check('types: NULL emitted unquoted', /,\s*NULL\s*,/.test(out), );
  check('types: bit true -> 1', /VALUES \(7, NULL, 1,/.test(out));
  check('types: date quoted', out.includes("N'2026-01-02'"));
  check('types: decimal unquoted', /12\.5\)/.test(out));
}

// --- 3. Never fabricate an expected: missing expected => smoke assert only
{
  const out = emit(base([{
    id: 'no expected', seed: [{ table: 'route.T', row: { Id: 1 } }],
    assert: { actual_expr: 'SELECT 1' }, needs_human_oracle: false,
  }]));
  check('no-expected: does NOT emit AssertEquals with a made-up value', !out.includes('AssertEquals @Expected ='));
  check('no-expected: emits a TODO capture marker', out.includes('TODO capture'));
}

// --- 4. needs_human_oracle => curated stub, never an auto expected
{
  const out = emit(base([{
    id: 'money rule', seed: [{ table: 'route.T', row: { Id: 1 } }],
    assert: { actual_expr: 'SELECT 1', expected: 999 }, needs_human_oracle: true,
  }]));
  check('oracle: routed to a CURATED STUB', out.includes('CURATED STUB'));
  check('oracle: stub says a human must state the value', out.includes('a human states the CORRECT value'));
  check('oracle: the 999 is NOT emitted as a passing AssertEquals', !out.includes('AssertEquals @Expected = 999'));
}

// --- 5. tSQLt requires the proc name to start with "test"
{
  const out = emit(base([{ id: 'branch without prefix', seed: [], assert: { actual_expr: 'SELECT 1', expected: 1 } }]));
  const m = out.match(/CREATE PROCEDURE \S+\.\[([^\]]+)\]/);
  check('tsqlt: generated proc name starts with "test"', !!m && /^test\b/i.test(m[1]), m ? m[1] : 'no proc found');
  const out2 = emit(base([{ id: 'test already prefixed', seed: [], assert: { actual_expr: 'SELECT 1', expected: 1 } }]));
  check('tsqlt: does not double-prefix an id already starting with "test"', !out2.includes('[test test '));
}

// --- 6. Zero branches => still valid, no crash, no bogus tests
{
  const out = emit(base([]));
  check('empty: 0 branches produces a class with no test procs', out.includes('NewTestClass') && !out.includes('CREATE PROCEDURE'));
}

// --- 7. Determinism
{
  const fx = base([{ id: 'd', seed: [{ table: 'route.T', row: { Id: 1, Name: 'a' } }], assert: { actual_expr: 'SELECT 1', expected: 1 } }]);
  check('determinism: two emits are byte-identical', emit(fx) === emit(fx));
}

// --- 8. Always drops+recreates the class (idempotent load)
{
  const out = emit(base([{ id: 'x', seed: [], assert: { actual_expr: 'SELECT 1', expected: 1 } }]));
  check('idempotent load: DropClass before NewTestClass', out.indexOf('DropClass') < out.indexOf('NewTestClass'));
  check('header states baselines pin CURRENT behaviour (not "correct")', out.includes('pin CURRENT behaviour'));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
