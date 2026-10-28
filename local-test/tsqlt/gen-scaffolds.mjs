#!/usr/bin/env node
// =============================================================================
// gen-scaffolds.mjs — turn docs/schemas/<schema>/test_scenarios.json into tSQLt test
// SCAFFOLDS under tests/generated/. Each scaffold pre-fills the mechanical parts we can
// derive deterministically — the test class, a tSQLt.FakeTable for every table the
// scenario seeds, the scenario's `action`, and the seed/expected text as TODO comments —
// then ends in tSQLt.Fail so it is RED until a human turns the English seed/assert into
// real INSERTs and AssertEquals and promotes it to tests/curated/.
//
// It intentionally does NOT invent assertions: turning an English "expected" into an
// AssertEquals is exactly where auto-generation gets things wrong, so a person finishes it.
// No DB access, no npm deps (Node built-ins only) — runs on any dev machine or in CI.
//
//   node local-test/tsqlt/gen-scaffolds.mjs            # all schemas
//   node local-test/tsqlt/gen-scaffolds.mjs rt cp      # only these schemas
// =============================================================================
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SCHEMAS_DIR = join(ROOT, 'docs', 'schemas');
const OUT_ROOT = join(ROOT, 'tests', 'generated');
const only = process.argv.slice(2);

// A schema.object token: lowercase schema, then an identifier. Used to find the tables a
// scenario seeds so we can FakeTable them. The target function/proc is excluded.
const TOKEN = /\b([a-z][a-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)/g;

function collectTables(scenario) {
    const text = [...(scenario.seed || []), scenario.action || ''].join('\n');
    const found = new Map();
    let m;
    while ((m = TOKEN.exec(text)) !== null) {
        const schema = m[1], obj = m[2];
        if (obj === scenario.target) continue;          // don't fake the object under test
        if (schema === 'dbo') continue;                 // helper functions, not fakeable tables
        found.set(`${schema}.${obj}`, true);
    }
    return [...found.keys()];
}

function scaffold(schema, s) {
    const cls = `test_${schema}_gen_${s.target}`;
    const name = `${s.id} ${(s.title || '').replace(/[[\]]/g, '')}`.trim();
    const tables = collectTables(s);
    const L = [];
    L.push(`-- AUTO-GENERATED SCAFFOLD — DO NOT SHIP AS-IS.`);
    L.push(`-- Source : docs/schemas/${schema}/test_scenarios.json → ${s.id}`);
    L.push(`-- Target : ${schema}.${s.target}`);
    if (s.rationale) L.push(`-- Why    : ${s.rationale}`);
    L.push(`-- Complete the SEED inserts and the ASSERT, then move this file to tests/curated/${schema}/`);
    L.push(`-- and delete the tSQLt.Fail line. It is RED until then, by design.`);
    L.push(`-- =============================================================================`);
    L.push(`IF SCHEMA_ID('${cls}') IS NOT NULL EXEC tSQLt.DropClass '${cls}';`);
    L.push(`GO`);
    L.push(`EXEC tSQLt.NewTestClass '${cls}';`);
    L.push(`GO`);
    L.push(`CREATE PROCEDURE ${cls}.[test ${name.replace(/'/g, "''")}]`);
    L.push(`AS`);
    L.push(`BEGIN`);
    if (tables.length) {
        L.push(`    -- Isolate the object under test: fake its dependencies (add/remove as needed).`);
        for (const t of tables) L.push(`    EXEC tSQLt.FakeTable '${t}';`);
        L.push('');
    }
    L.push(`    -- SEED — turn each line into an INSERT (synthetic values only, no prod data):`);
    for (const seed of (s.seed || ['(no seed documented)'])) L.push(`    --   ${seed}`);
    L.push('');
    L.push(`    -- ACTION (from the scenario):`);
    L.push(`    -- ${s.action || '(no action documented)'}`);
    L.push('');
    L.push(`    -- ASSERT — turn each expectation into a tSQLt assertion:`);
    for (const e of (s.expected || ['(no expectation documented)'])) L.push(`    --   ${e}`);
    L.push('');
    L.push(`    EXEC tSQLt.Fail 'TODO: complete this auto-generated scaffold for ${s.id}';`);
    L.push(`END`);
    L.push(`GO`);
    return { cls, body: L.join('\n') + '\n' };
}

function main() {
    if (!existsSync(SCHEMAS_DIR)) { console.error(`No ${SCHEMAS_DIR}`); process.exit(0); }
    let schemas = readdirSync(SCHEMAS_DIR, { withFileTypes: true }).filter(d => d.isDirectory()).map(d => d.name);
    if (only.length) schemas = schemas.filter(s => only.includes(s));
    let made = 0, skipped = 0;
    for (const schema of schemas) {
        const f = join(SCHEMAS_DIR, schema, 'test_scenarios.json');
        if (!existsSync(f)) continue;
        let doc;
        try { doc = JSON.parse(readFileSync(f, 'utf8')); }
        catch (e) { console.error(`  ! ${schema}/test_scenarios.json: ${e.message}`); continue; }
        for (const s of (doc.scenarios || [])) {
            if (!s.target || !s.id) continue;
            // If a curated test already covers this scenario, don't shadow it with a red scaffold.
            if (s.curatedTest && existsSync(join(ROOT, s.curatedTest))) {
                console.log(`  = ${schema}/${s.id}: curated test exists (${s.curatedTest}) — skipped`);
                skipped++; continue;
            }
            const { cls, body } = scaffold(schema, s);
            const outDir = join(OUT_ROOT, schema);
            mkdirSync(outDir, { recursive: true });
            const outFile = join(outDir, `${cls}__${s.id}.sql`);
            writeFileSync(outFile, body);
            console.log(`  + ${schema}/${s.id} -> tests/generated/${schema}/${cls}__${s.id}.sql (${collectTables(s).length} FakeTable)`);
            made++;
        }
    }
    console.log(`Done: ${made} scaffold(s) generated, ${skipped} skipped (curated).`);
}
main();
