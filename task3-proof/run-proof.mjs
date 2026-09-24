import { PGlite } from '@electric-sql/pglite';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import assert from 'node:assert/strict';
process.chdir(new URL('.', import.meta.url).pathname);
await mkdir('evidence',{recursive:true});
const notices=[];
const db=new PGlite();
const read=p=>readFile(p,'utf8');
try {
 const version=(await db.query('select version()')).rows[0].version;
 await db.exec(await read('migration.sql')); console.log('Migration passed');
 await db.exec(await read('seed.sql')); console.log('Seed passed');
 const counts=(await db.query(`SELECT 'orders' AS entity,count(*) FROM orders UNION ALL SELECT 'order_item',count(*) FROM order_item UNION ALL SELECT 'delivery',count(*) FROM delivery UNION ALL SELECT 'review',count(*) FROM review`)).rows;
 const queries=await db.exec(await read('queries.sql'));
 assert.equal(queries.length,5); for(const q of queries) assert.ok(q.rows.length>0,'Each action query should return data');
 await writeFile('evidence/five-queries.json',JSON.stringify(queries.map((q,i)=>({action:i+1,rows:q.rows})),null,2));
 const plans=await db.exec(await read('plans.sql'));
 const planText=plans.map((p,i)=>`QUERY PLAN ${i+1}\n`+p.rows.map(r=>r['QUERY PLAN']).join('\n')).join('\n\n');
 assert.match(planText,/restaurant_orders/); assert.match(planText,/assignable_orders/);
 await writeFile('evidence/query-plans.txt',version+'\n\n'+planText+'\n');
 await db.exec(await read('invalid-inserts.sql'),{onNotice:n=>notices.push(n.message)});
 const invalid=notices.filter(x=>x.startsWith('PASS invalid insert')); assert.equal(invalid.length,3);
 await writeFile('evidence/invalid-inserts.txt',version+'\n'+invalid.join('\n')+'\n');
 const checks=[];
 async function rejects(label,sql,pattern){
  await db.exec('BEGIN');
  try {await db.exec(sql); await db.exec('SET CONSTRAINTS ALL IMMEDIATE'); assert.fail('Invalid write succeeded: '+label);}
  catch(e){assert.match(e.message,pattern); checks.push('PASS '+label+': '+e.message);}
  finally {await db.exec('ROLLBACK');}
 }
 await rejects('empty order',`INSERT INTO orders(customer_id,restaurant_id,delivery_address_snapshot,total_minor,currency) SELECT (SELECT id FROM customer LIMIT 1),id,'{}',1200,'USD' FROM restaurant LIMIT 1`,/order_requires_items/);
 await rejects('total mismatch',`WITH o AS (INSERT INTO orders(customer_id,restaurant_id,delivery_address_snapshot,total_minor,currency) SELECT (SELECT id FROM customer LIMIT 1),restaurant_id,'{}',1201,'USD' FROM menu_item LIMIT 1 RETURNING *) INSERT INTO order_item(order_id,menu_item_id,quantity,unit_price_minor,currency) SELECT o.id,m.id,1,m.price_minor,m.currency FROM o JOIN menu_item m ON m.restaurant_id=o.restaurant_id`,/order_total_matches_items/);
 await rejects('forbidden state transition',`UPDATE orders SET status='delivered' WHERE id=(SELECT id FROM orders WHERE status='placed' LIMIT 1)`,/invalid_order_transition/);
 await rejects('immutable review order',`UPDATE review SET order_id=(SELECT id FROM orders WHERE status='placed' LIMIT 1) WHERE id=(SELECT id FROM review LIMIT 1)`,/immutable field/);
 await db.exec('BEGIN');
 const snapshotSql=`SELECT oi.id,oi.unit_price_minor FROM order_item oi JOIN menu_item m ON m.id=oi.menu_item_id WHERE m.restaurant_id=(SELECT id FROM restaurant WHERE name='Kitchen 1') ORDER BY oi.id`;
 const before=await db.query(snapshotSql);
 await db.exec(`UPDATE menu_item SET price_minor=1800 WHERE restaurant_id=(SELECT id FROM restaurant WHERE name='Kitchen 1')`);
 assert.deepEqual((await db.query(snapshotSql)).rows,before.rows); await db.exec('ROLLBACK'); checks.push('PASS historical prices survive menu price changes');
 await writeFile('evidence/additional-checks.txt',checks.join('\n')+'\n');
 const report={runtime:version,counts,actionQueriesPassed:5,invalidInsertsRejected:3,additionalChecks:checks.length,indexesObserved:['restaurant_orders','assignable_orders'],concurrencyTest:'NOT RUN: embedded single-connection runtime; native server blocked by sandbox shared-memory restriction'};
 await writeFile('evidence/summary.json',JSON.stringify(report,null,2));
 const escape=x=>String(x).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
 await writeFile('evidence/constraint-results.html',`<!doctype html><html><meta charset="utf-8"><title>Executed database constraint checks</title><style>body{font:17px system-ui;max-width:1080px;margin:40px;color:#172128;background:#f6f8fa}h1{font-size:28px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:white;padding:24px;border:1px solid #ccd4da;line-height:1.7}small{color:#4d5d68}</style><h1>Task 3 — rejected invalid inserts</h1><p>Actual results from executing invalid-inserts.sql against the migrated and seeded database.</p><pre>${escape(invalid.join('\n\n'))}</pre><small>${escape(version)}<br>Single-connection execution; concurrent assignment race not tested.</small></html>`);
 console.log(JSON.stringify(report,null,2));
} finally {await db.close();}
