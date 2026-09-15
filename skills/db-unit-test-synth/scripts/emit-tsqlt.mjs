#!/usr/bin/env node
// emit-tsqlt.mjs — turn a completed fixture (from introspect.sh + Claude's branch reasoning)
// into a runnable tSQLt characterization class. Deterministic: all judgement is already in the
// fixture's branches[]; this only serializes it.
//
//   node emit-tsqlt.mjs fixture.json [--curated-dir tests/curated]
//
// Fixture branch shape (Claude fills branches[]):
//   { "id": "human label",
//     "fake": ["rt.RoutingPlanCoverage", ...],          // optional; defaults to fixture.fake
//     "seed": [ {"table":"rt.RoutingPlanCoverage","row":{"Col":val,...}}, ... ],
//     "assert": { "actual_expr":"(SELECT RoutingGroupId FROM rt.fnSubAccountRoutingGroup('108','AF'))",
//                 "expected": 111,                        // golden value, captured after 1st run
//                 "message":"..." },
//     "needs_human_oracle": false }
//
// A branch with needs_human_oracle:true (or no assert.expected) is emitted as a CURATED STUB with a
// TODO expected, so a human supplies the correctness oracle — never a fabricated golden value.

import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const args = process.argv.slice(2);
const fixturePath = args.find(a => !a.startsWith('--'));
const curatedDir = (() => { const i = args.indexOf('--curated-dir'); return i >= 0 ? args[i + 1] : null; })();
if (!fixturePath) { console.error('usage: emit-tsqlt.mjs fixture.json [--curated-dir DIR]'); process.exit(2); }

const fx = JSON.parse(readFileSync(fixturePath, 'utf8'));
const [schema, object] = fx.object.split('.');
const cls = `test_${schema}_${object}`;
const isScalarFn = fx.type === 'SQL_SCALAR_FUNCTION';
const defaultFake = (fx.fake || []).map(f => `${f.schema}.${f.table}`);

// Build a column->type map so we format literals correctly (string vs numeric vs date vs bit).
const typeOf = {};
for (const t of (fx.tables || []))
    for (const c of (t.columns || []))
        typeOf[`${t.schema}.${t.table}.${c.name}`] = (c.type || '').toLowerCase();

const NUMERIC = new Set(['tinyint','smallint','int','bigint','decimal','numeric','money','smallmoney','float','real']);
const STRINGY = new Set(['char','nchar','varchar','nvarchar','text','ntext','uniqueidentifier','xml']);
const DATEY   = new Set(['date','datetime','datetime2','smalldatetime','datetimeoffset','time']);

function lit(table, col, v) {
    if (v === null || v === undefined) return 'NULL';
    const t = typeOf[`${table}.${col}`] || '';
    if (typeof v === 'boolean') return v ? '1' : '0';
    if (typeof v === 'number') return String(v);
    if (t === 'bit') return (v === true || v === 1 || v === '1') ? '1' : '0';
    if (NUMERIC.has(t)) return String(v);
    if (STRINGY.has(t) || DATEY.has(t) || t === '') return `N'${String(v).replace(/'/g, "''")}'`;
    return `N'${String(v).replace(/'/g, "''")}'`;
}

function seedInserts(seed) {
    const out = [];
    for (const s of (seed || [])) {
        const cols = Object.keys(s.row);
        const vals = cols.map(c => lit(s.table, c, s.row[c]));
        out.push(`\tINSERT ${s.table} (${cols.join(', ')})\n\t\tVALUES (${vals.join(', ')});`);
    }
    return out.join('\n');
}

function fakeBlock(branch) {
    const set = new Set([...(branch.fake || defaultFake), ...((branch.seed || []).map(s => s.table))]);
    return [...set].map(f => `\tEXEC tSQLt.FakeTable '${f}';`).join('\n');
}

function testProc(branch) {
    // tSQLt only runs procedures whose name starts with "test" — enforce it.
    const label = branch.id.replace(/]/g, '');
    const name = `[${/^test\b/i.test(label) ? label : 'test ' + label}]`;
    const a = branch.assert || {};
    const actual = a.actual_expr || (isScalarFn ? `SELECT ${fx.object}(${(branch.call?.args || []).map(x => typeof x === 'number' ? x : `N'${String(x).replace(/'/g,"''")}'`).join(', ')})` : null);
    const msg = (a.message || `${branch.id} (characterization — current behaviour pinned)`).replace(/'/g, "''");
    let body = `\t-- ${branch.id}\n${fakeBlock(branch)}\n\n${seedInserts(branch.seed)}\n\n`;
    if (a.expected !== undefined && a.expected !== null) {
        body += `\tDECLARE @actual SQL_VARIANT = (${actual});\n`;
        const exp = typeof a.expected === 'number' ? a.expected : `N'${String(a.expected).replace(/'/g, "''")}'`;
        body += `\tEXEC tSQLt.AssertEquals @Expected = ${exp}, @Actual = @actual,\n\t\t@Message = '${msg}';`;
    } else {
        // No golden value yet: emit a runnable smoke assert (executes the code -> counts for coverage)
        // and print the observed value so a human/CI can freeze it. NEVER fabricate an expected.
        body += `\tDECLARE @actual SQL_VARIANT = (${actual || 'SELECT 1'});\n`;
        body += `\t-- TODO capture: first run prints @actual; freeze it as @Expected above.\n`;
        body += `\tEXEC tSQLt.AssertNotEquals @Expected = NULL, @Actual = @actual,\n\t\t@Message = '${msg} — smoke only, expected not yet frozen';`;
    }
    return `CREATE PROCEDURE ${cls}.${name}\nAS\nBEGIN\n${body}\nEND\nGO\n`;
}

const auto = (fx.branches || []).filter(b => !b.needs_human_oracle);
const oracle = (fx.branches || []).filter(b => b.needs_human_oracle);

let out = '';
out += `-- =============================================================================\n`;
out += `-- Characterization tSQLt tests for ${fx.object}  (${fx.type})\n`;
out += `-- GENERATED by db-unit-test-synth. Assertions pin CURRENT behaviour (golden master),\n`;
out += `-- not proven-correct behaviour. ${oracle.length} branch(es) needing a human oracle were\n`;
out += `-- emitted as curated stubs${curatedDir ? ` under ${curatedDir}` : ' (see end of file)'}.\n`;
out += `-- All seed values are synthetic; no production rows. Report-only stage.\n`;
out += `-- =============================================================================\n`;
out += `IF SCHEMA_ID('${cls}') IS NOT NULL EXEC tSQLt.DropClass '${cls}';\nGO\n`;
out += `EXEC tSQLt.NewTestClass '${cls}';\nGO\n`;
for (const b of auto) out += testProc(b);

if (oracle.length) {
    const stub = oracle.map(b => `-- CURATED STUB: ${b.id}\n-- ${b.assert?.actual_expr || ''}\n-- Expected = /* TODO: a human states the CORRECT value */`).join('\n\n');
    if (curatedDir) {
        const p = join(curatedDir, schema, `${cls}.needs_oracle.sql`);
        mkdirSync(dirname(p), { recursive: true });
        writeFileSync(p, stub + '\n');
        console.error(`wrote ${oracle.length} curated stub(s) -> ${p}`);
    } else {
        out += `\n/* ---- ${oracle.length} branch(es) need a human oracle (correctness, not regression) ----\n${stub}\n*/\n`;
    }
}

process.stdout.write(out);
